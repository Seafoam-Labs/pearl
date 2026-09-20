//! Post-commit application rendering and conditional ownership. All paths are
//! selected by built-in adapters; no profile hooks or contributed destinations.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const profiles = @import("matugen_profiles.zig");
const provider = @import("theme_provider.zig");
const model = @import("package_model.zig");
const io = @import("../config/io.zig");
const safe = @import("../config/qt_integration.zig");
const c = @import("package.zig").c;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
const max_snapshot = 4 * 1024 * 1024;
const Runtime = struct { schema_version: u32 = 1, key: []const u8, snapshot: provider.Snapshot };
fn runtimeKey(a: std.mem.Allocator, p: @import("../config/preferences.zig").Preferences) ![]const u8 {
    return a.dupe(u8, &model.hash(try std.json.Stringify.valueAlloc(a, .{
        .selection = try provider.selectionKey(a, p),
        .committed = p.matugen.snapshot_digest,
        .colors = p.matugen.colors,
        .source = p.theme.source,
        .seed = p.theme.seed,
        .wallpaper = p.wallpaper.path,
    }, .{})));
}
pub fn saveRuntime(a: std.mem.Allocator, root: []const u8, p: @import("../config/preferences.zig").Preferences, snapshot: provider.Snapshot) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, Runtime{ .key = try runtimeKey(a, p), .snapshot = snapshot }, .{});
    if (bytes.len > max_snapshot) return error.ProfileSnapshotLimit;
    try io.atomic(try std.fmt.allocPrintSentinel(a, "{s}/matugen/runtime.json", .{root}, 0), bytes, false);
}
pub fn loadRuntime(a: std.mem.Allocator, root: []const u8, p: @import("../config/preferences.zig").Preferences) !?provider.Snapshot {
    const file = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/matugen/runtime.json", .{root}, 0), max_snapshot, null);
    if (file.missing) return null;
    const runtime = try model.parse(Runtime, a, file.bytes, max_snapshot);
    if (runtime.schema_version != 1 or !std.mem.eql(u8, runtime.key, try runtimeKey(a, p))) return null;
    try validateSnapshot(runtime.snapshot);
    return runtime.snapshot;
}
pub fn snapshotPath(a: std.mem.Allocator, root: []const u8, digest: []const u8) ![:0]const u8 {
    try model.digest(digest);
    return std.fmt.allocPrintSentinel(a, "{s}/matugen/snapshots/{s}.json", .{ root, digest }, 0);
}
pub fn save(a: std.mem.Allocator, root: []const u8, snapshot: provider.Snapshot) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    if (bytes.len > max_snapshot) return error.ProfileSnapshotLimit;
    const digest = try a.dupe(u8, &model.hash(bytes));
    const path = try snapshotPath(a, root, digest);
    const directory = try a.dupeZ(u8, std.fs.path.dirname(path).?);
    const fd = try safe.directory(a, directory, true);
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return error.ProfileSnapshotLimit;
    };
    defer _ = c.closedir(dir);
    const old = try io.read(a, path, max_snapshot, null);
    if (!old.missing) {
        if (!std.mem.eql(u8, old.bytes, bytes)) return error.ProfileSnapshotCorrupt;
        return digest;
    }
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count >= 32) return error.ProfileSnapshotLimit;
    }
    try io.atomic(path, bytes, true);
    return digest;
}
pub fn load(a: std.mem.Allocator, root: []const u8, digest: []const u8) !provider.Snapshot {
    const file = try io.read(a, try snapshotPath(a, root, digest), max_snapshot, null);
    if (file.missing or !std.mem.eql(u8, &file.hash, digest)) return error.ProfileSnapshotCorrupt;
    const result = try model.parse(provider.Snapshot, a, file.bytes, max_snapshot);
    try validateSnapshot(result);
    return result;
}
fn validateSnapshot(result: provider.Snapshot) !void {
    if (result.schema_version != 1 or result.profiles.len > 5) return error.ProfileSnapshotCorrupt;
    for (result.profiles) |profile| {
        try model.identifier(profile.id);
        if (profile.descriptor) |descriptor| {
            try descriptor.validate();
            if (!std.mem.eql(u8, descriptor.id, profile.id) or descriptor.application != profile.application or profile.templates.len != descriptor.templates.len) return error.ProfileSnapshotCorrupt;
            for (profile.templates) |template| {
                try model.identifier(template.path);
                try profiles.template(template.bytes);
            }
        }
    }
}
pub fn prune(a: std.mem.Allocator, root: []const u8, retained: []const []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/matugen/snapshots", .{root}, 0);
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return;
    };
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        count += 1;
        if (count > 34) return error.ProfileSnapshotLimit;
        if (name.len != 69 or !std.mem.endsWith(u8, name, ".json")) continue;
        var keep = false;
        for (retained) |digest| if (std.mem.eql(u8, digest, name[0..64])) {
            keep = true;
        };
        if (keep) continue;
        model.digest(name[0..64]) catch continue;
        const bytes = @import("package.zig").read(a, fd, name, max_snapshot) catch continue;
        if (std.mem.eql(u8, &model.hash(bytes), name[0..64])) _ = c.unlinkat(fd, @ptrCast(&entry.*.d_name), 0);
    }
}
pub const Output = struct { name: []const u8, bytes: []const u8 };
pub fn render(a: std.mem.Allocator, captured: provider.Captured, snapshot: provider.Snapshot, scratch_root: [:0]const u8, cancel: *gio.Cancellable) ![]const Output {
    var context: @import("generator.zig").Context = .{};
    return renderWithContext(a, captured, snapshot, scratch_root, cancel, &context);
}
pub fn renderWithContext(a: std.mem.Allocator, captured: provider.Captured, snapshot: provider.Snapshot, scratch_root: [:0]const u8, cancel: *gio.Cancellable, context: *@import("generator.zig").Context) ![]const Output {
    if (captured.error_code != null or captured.descriptor == null) return error.ProfileUnavailable;
    const input = snapshot.render_json orelse return error.CompleteRenderPaletteUnavailable;
    const version = try context.getVersion(a, cancel);
    try io.mkdir(scratch_root);
    const key = model.hash(try std.json.Stringify.valueAlloc(a, .{ .adapter_api = @as(u32, 2), .renderer = version, .captured = captured, .input = input, .variant = snapshot.variant }, .{}));
    const slot = std.fmt.parseInt(u8, key[0..2], 16) catch unreachable;
    // Three bounded slots per adapter prevent another application's render from
    // evicting the current input. Retrying a failed target reuses the others.
    const cache_path = try std.fmt.allocPrintSentinel(a, "{s}/render-cache-{d}.json", .{ scratch_root, @as(usize, @intFromEnum(captured.application)) * 3 + slot % 3 }, 0);
    const Cache = struct { key: []const u8, outputs: []const Output, digest: []const u8 };
    if (io.read(a, cache_path, 2 * 1024 * 1024, cancel)) |cache| {
        if (!cache.missing) if (model.parse(Cache, a, cache.bytes, 2 * 1024 * 1024)) |value| {
            if (std.mem.eql(u8, value.key, &key) and value.outputs.len == captured.templates.len) {
                var valid = std.mem.eql(u8, value.digest, &model.hash(try std.json.Stringify.valueAlloc(a, value.outputs, .{})));
                for (value.outputs, captured.templates) |output, template| {
                    if (!std.mem.eql(u8, output.name, template.path) or output.bytes.len == 0 or output.bytes.len > 131072) valid = false;
                }
                if (valid) return value.outputs;
            }
        } else |_| {};
    } else |_| {}
    const scratch = try std.fmt.allocPrintSentinel(a, "{s}/render-XXXXXX", .{scratch_root}, 0);
    if (mkdtemp(scratch) == null) return error.ProfileStagingFailed;
    defer @import("install.zig").removeTree(a, scratch) catch {};
    const json = try std.fmt.allocPrintSentinel(a, "{s}/colors.json", .{scratch}, 0);
    // Matugen JSON import preserves the input's default entries despite --mode.
    // Select complete supplied values explicitly; never regenerate fixed colors.
    try @import("../config/preferences.zig").boundedJson(input, 131072, 16);
    var document = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{});
    if (document != .object) return error.InvalidRenderData;
    for ([_][]const u8{ "colors", "base16" }) |section| {
        const colors = document.object.getPtr(section) orelse return error.InvalidRenderData;
        if (colors.* != .object) return error.InvalidRenderData;
        for (colors.object.values()) |*color| {
            if (color.* != .object) return error.InvalidRenderData;
            const selected = color.object.get(@tagName(snapshot.variant)) orelse return error.InvalidRenderData;
            try color.object.put(a, "default", selected);
        }
    }
    if (document.object.getPtr("mode")) |mode| mode.* = .{ .string = @tagName(snapshot.variant) };
    if (document.object.getPtr("is_dark_mode")) |dark| dark.* = .{ .bool = snapshot.variant == .dark };
    try io.atomic(json, try std.json.Stringify.valueAlloc(a, document, .{}), true);
    var config: std.ArrayList(u8) = .empty;
    try config.appendSlice(a, "[config]\n");
    for (captured.templates, 0..) |template, i| {
        const in_path = try std.fmt.allocPrintSentinel(a, "{s}/input-{d}", .{ scratch, i }, 0);
        const out_path = try std.fmt.allocPrintSentinel(a, "{s}/output-{d}", .{ scratch, i }, 0);
        try io.atomic(in_path, template.bytes, true);
        try config.appendSlice(a, try std.fmt.allocPrint(a, "[templates.t{d}]\ninput_path = {s}\noutput_path = {s}\n", .{ i, try std.json.Stringify.valueAlloc(a, in_path, .{}), try std.json.Stringify.valueAlloc(a, out_path, .{}) }));
    }
    const config_path = try std.fmt.allocPrintSentinel(a, "{s}/matugen.toml", .{scratch}, 0);
    try io.atomic(config_path, config.items, true);
    _ = try @import("generator.zig").run(a, &.{ "matugen", "--quiet", "--config", config_path, "--mode", @tagName(snapshot.variant), "json", json }, cancel);
    var result: std.ArrayList(Output) = .empty;
    for (captured.templates, 0..) |template, i| {
        const file = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/output-{d}", .{ scratch, i }, 0), 131072, cancel);
        if (file.missing or file.bytes.len == 0 or !std.unicode.utf8ValidateSlice(file.bytes) or std.mem.indexOf(u8, file.bytes, "{{") != null) return error.InvalidProfileOutput;
        if (captured.application == .zed) {
            try @import("../config/preferences.zig").boundedJson(file.bytes, 131072, 16);
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, file.bytes, .{});
            if (value != .object or !value.object.contains("themes")) return error.InvalidProfileOutput;
        }
        try result.append(a, .{ .name = template.path, .bytes = file.bytes });
    }
    const cached = try std.json.Stringify.valueAlloc(a, Cache{ .key = &key, .outputs = result.items, .digest = &model.hash(try std.json.Stringify.valueAlloc(a, result.items, .{})) }, .{});
    if (cached.len <= 2 * 1024 * 1024) io.atomic(cache_path, cached, false) catch {};
    return result.items;
}
const Record = struct { name: []const u8, original: ?[]const u8 = null, last: []const u8 = "", next: []const u8 = "", pending: bool = false };
const Ledger = struct { schema_version: u32 = 1, records: []Record = &.{} };
fn ledgerSave(a: std.mem.Allocator, path: [:0]const u8, records: []const Record) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .schema_version = @as(u32, 1), .records = records }, .{});
    if (bytes.len > 2 * 1024 * 1024) return error.ProfileLedgerLimit;
    try io.atomic(path, bytes, false);
}
fn destination(a: std.mem.Allocator, config: []const u8, application: profiles.Application) ![]const u8 {
    if (application == .equibop) if (glib.getenv("EQUICORD_USER_DATA_DIR")) |root| return std.fmt.allocPrint(a, "{s}/themes", .{std.mem.span(root)});
    if (application == .starship and glib.getenv("STARSHIP_CONFIG") != null) return error.CustomStarshipConfigRequiresManualSetup;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ config, switch (application) {
        .zed => "zed/themes",
        .equibop => "equibop/themes",
        .starship => "",
        else => return error.ManualProfileActivation,
    } });
}
/// One application journal is committed stepwise. Preflight every destination
/// before writing; recover each pending step from its content hash after a crash.
fn install(a: std.mem.Allocator, config: []const u8, state: [:0]const u8, application: profiles.Application, outputs: []const Output, cancel: *gio.Cancellable, reviewed: bool) !void {
    const journal = try std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ state, @tagName(application) }, 0);
    const stored = try io.read(a, journal, 2 * 1024 * 1024, cancel);
    if (stored.missing and outputs.len == 0) return;
    var ledger: Ledger = if (stored.missing) .{} else try model.parse(Ledger, a, stored.bytes, 2 * 1024 * 1024);
    if (ledger.schema_version != 1 or ledger.records.len > 16) return error.InvalidProfileLedger;
    const root = try destination(a, config, application);
    const fd = try safe.directory(a, root, true);
    defer _ = c.close(fd);
    var records: std.ArrayList(Record) = .empty;
    for (ledger.records, 0..) |*record, i| {
        try outputName(record.name);
        if (application == .starship) {
            if (!std.mem.eql(u8, record.name, "starship.toml")) return error.InvalidProfileLedger;
        } else if (!std.mem.startsWith(u8, record.name, "pearl-")) return error.InvalidProfileLedger;
        for (ledger.records[0..i]) |old| if (std.mem.eql(u8, old.name, record.name)) return error.InvalidProfileLedger;
        if (record.original) |bytes| if (bytes.len > 131072) return error.InvalidProfileLedger;
        for ([_][]const u8{ record.last, record.next }) |digest| if (digest.len > 0) try model.digest(digest);
        const path = try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, record.name }, 0);
        const current = try io.read(a, path, 131072, cancel);
        if (record.pending) {
            if (std.mem.eql(u8, &current.hash, record.next)) record.last = record.next else if (!std.mem.eql(u8, &current.hash, record.last)) return error.ProfileOwnershipConflict;
            record.pending = false;
        }
        if (!std.mem.eql(u8, &current.hash, record.last)) return error.ProfileOwnershipConflict;
        try records.append(a, record.*);
    }
    for (outputs) |output| {
        try outputName(output.name);
        var found = false;
        for (records.items) |record| if (std.mem.eql(u8, record.name, output.name)) {
            found = true;
        };
        if (!found) {
            const path = try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, output.name }, 0);
            const current = try io.read(a, path, 131072, cancel);
            if (!current.missing and !reviewed) return error.ProfileOwnershipConflict;
            try records.append(a, .{ .name = output.name, .original = if (current.missing) null else current.bytes, .last = try a.dupe(u8, &current.hash) });
        }
    }
    if (records.items.len > 16) return error.ProfileLedgerLimit;
    for (records.items) |*record| {
        var desired: ?[]const u8 = record.original;
        for (outputs) |output| if (std.mem.eql(u8, output.name, record.name)) {
            desired = output.bytes;
        };
        const hash = if (desired) |bytes| model.hash(bytes) else model.hash("missing");
        if (std.mem.eql(u8, record.last, &hash)) continue;
        record.pending = true;
        record.next = try a.dupe(u8, &hash);
        try ledgerSave(a, journal, records.items);
        const path = try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, record.name }, 0);
        const current = try io.read(a, path, 131072, cancel);
        if (!std.mem.eql(u8, &current.hash, record.last)) return error.ProfileOwnershipConflict;
        if (desired) |bytes| try io.replace(path, bytes, current, cancel) else {
            if (!current.missing and c.unlinkat(fd, try a.dupeZ(u8, record.name), 0) != 0) return error.ProfileRestoreFailed;
            if (c.fsync(fd) != 0) return error.ProfileRestoreFailed;
        }
        record.last = record.next;
        record.pending = false;
        try ledgerSave(a, journal, records.items);
    }
    // Retain only destinations still managed. Restored records no longer own files.
    var retained: std.ArrayList(Record) = .empty;
    for (records.items) |record| for (outputs) |output| if (std.mem.eql(u8, record.name, output.name)) {
        try retained.append(a, record);
        break;
    };
    try ledgerSave(a, journal, retained.items);
}
fn outputName(name: []const u8) !void {
    if (name.len == 0 or name.len > 240) return error.InvalidProfileOutputName;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '_')) return error.InvalidProfileOutputName;
    if (name[0] == '.') return error.InvalidProfileOutputName;
}
pub const Review = struct { digest: []const u8, current: []const u8, proposed: []const u8, profile: []const u8, destination: []const u8 };
pub fn reviewStarship(a: std.mem.Allocator, config: []const u8, snapshot: provider.Snapshot, cancel: *gio.Cancellable) !Review {
    if (snapshot.error_code != null) return error.ProfileUnavailable;
    var selected: ?provider.Captured = null;
    for (snapshot.profiles) |profile| if (profile.application == .starship) {
        selected = profile;
    };
    const profile = selected orelse return error.ProfileUnavailable;
    const scratch = try std.fmt.allocPrintSentinel(a, "{s}/pearl/matugen", .{std.mem.span(glib.getUserCacheDir())}, 0);
    const generated = try render(a, profile, snapshot, scratch, cancel);
    if (generated.len != 1) return error.InvalidProfile;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/starship.toml", .{try destination(a, config, .starship)}, 0);
    const current = try io.read(a, path, 131072, cancel);
    if (current.bytes.len + generated[0].bytes.len > 48000) return error.ProfileReviewTooLarge;
    const identity = try std.json.Stringify.valueAlloc(a, .{ .snapshot = snapshot, .current = current.hash, .proposed = generated[0].bytes, .destination = path }, .{});
    return .{ .digest = try a.dupe(u8, &model.hash(identity)), .current = current.bytes, .proposed = generated[0].bytes, .profile = profile.id, .destination = path };
}
pub fn installStarship(a: std.mem.Allocator, config: []const u8, snapshot: provider.Snapshot, expected: []const u8, cancel: *gio.Cancellable) !void {
    return installStarshipGuarded(a, config, snapshot, expected, cancel, .{});
}
pub fn installStarshipGuarded(a: std.mem.Allocator, config: []const u8, snapshot: provider.Snapshot, expected: []const u8, cancel: *gio.Cancellable, guard: @import("publication.zig").Guard) !void {
    try model.digest(expected);
    const state = try std.fmt.allocPrintSentinel(a, "{s}/pearl/matugen", .{config}, 0);
    const fd = try safe.directory(a, state, true);
    defer _ = c.close(fd);
    const lock = c.openat(fd, "writer.lock", c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock < 0) return error.ProfileWriterUnavailable;
    defer _ = c.close(lock);
    if (std.os.linux.errno(std.os.linux.flock(lock, 2 | 4)) != .SUCCESS) return error.ProfileWriterBusy;
    const review = try reviewStarship(a, config, snapshot, cancel);
    if (!std.mem.eql(u8, review.digest, expected)) return error.ProfileReviewChanged;
    try guard.begin(cancel);
    defer guard.end();
    try install(a, config, state, .starship, &.{.{ .name = "starship.toml", .bytes = review.proposed }}, cancel, true);
}
pub fn reconcile(a: std.mem.Allocator, config: []const u8, enabled: bool, snapshot: provider.Snapshot, cancel: *gio.Cancellable) !profiles.Status {
    var context: @import("generator.zig").Context = .{};
    return reconcileGuarded(a, config, enabled, snapshot, cancel, &context, .{});
}
pub fn reconcileGuarded(a: std.mem.Allocator, config: []const u8, enabled: bool, snapshot: provider.Snapshot, cancel: *gio.Cancellable, context: *@import("generator.zig").Context, guard: @import("publication.zig").Guard) !profiles.Status {
    var status: profiles.Status = .{};
    if (enabled) if (snapshot.error_code) |code| {
        for (&status.targets) |*target| target.* = .{ .state = .unavailable, .error_code = code };
        return status;
    };
    const state = try std.fmt.allocPrintSentinel(a, "{s}/pearl/matugen", .{config}, 0);
    if (!enabled and glib.fileTest(state, .{ .exists = true }) == 0) return status;
    const fd = try safe.directory(a, state, true);
    defer _ = c.close(fd);
    const lock = c.openat(fd, "writer.lock", c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock < 0) return error.ProfileWriterUnavailable;
    defer _ = c.close(lock);
    if (std.os.linux.errno(std.os.linux.flock(lock, 2 | 4)) != .SUCCESS) return error.ProfileWriterBusy;
    const scratch = try std.fmt.allocPrintSentinel(a, "{s}/pearl/matugen", .{std.mem.span(glib.getUserCacheDir())}, 0);
    for (std.enums.values(profiles.Application), 0..) |application, i| {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        var selected: ?provider.Captured = null;
        if (enabled) for (snapshot.profiles) |profile| if (profile.application == application) {
            selected = profile;
        };
        if (selected) |profile| {
            status.targets[i] = .{ .profile = profile.id, .origin = profile.origin, .instructions = if (profile.descriptor) |descriptor| descriptor.instructions else "" };
            if (profile.error_code) |err| {
                status.targets[i].state = .unavailable;
                status.targets[i].error_code = err;
                continue;
            }
            const generated = renderWithContext(a, profile, snapshot, scratch, cancel, context) catch |err| {
                status.targets[i].state = if (err == error.CompleteRenderPaletteUnavailable) .unsupported else .failed;
                status.targets[i].error_code = @errorName(err);
                continue;
            };
            try guard.begin(cancel);
            defer guard.end();
            // Five fixed adapter directories bound durable generated output even
            // when arbitrary community profile IDs are installed and removed.
            const output_root = try std.fmt.allocPrintSentinel(a, "{s}/outputs/{s}", .{ state, @tagName(application) }, 0);
            const output_fd = try safe.directory(a, output_root, true);
            defer _ = c.close(output_fd);
            var installed: std.ArrayList(Output) = .empty;
            for (generated, 0..) |output, output_index| {
                const extension = std.fs.path.extension(output.name);
                const path = try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/output-{d}{s}", .{ output_fd, output_index, extension }, 0);
                const old = try io.read(a, path, 131072, cancel);
                if (old.missing or !std.mem.eql(u8, old.bytes, output.bytes)) try io.replace(path, output.bytes, old, cancel);
                try installed.append(a, .{ .name = try std.fmt.allocPrint(a, "pearl-{s}-{s}", .{ profile.id, output.name }), .bytes = output.bytes });
            }
            status.targets[i].output = output_root;
            status.targets[i].state = .activation_required;
            if (application == .starship) {
                const journal = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/starship.json", .{state}, 0), 2 * 1024 * 1024, cancel);
                if (!journal.missing and (try model.parse(Ledger, a, journal.bytes, 2 * 1024 * 1024)).records.len > 0) {
                    install(a, config, state, .starship, &.{.{ .name = "starship.toml", .bytes = generated[0].bytes }}, cancel, false) catch |err| {
                        status.targets[i].state = if (err == error.ProfileOwnershipConflict) .conflict else .failed;
                        status.targets[i].error_code = @errorName(err);
                        continue;
                    };
                    status.targets[i].state = .applied;
                }
            }
            if (application == .zed or application == .equibop) install(a, config, state, application, installed.items, cancel, false) catch |err| {
                status.targets[i].state = if (err == error.ProfileOwnershipConflict) .conflict else .failed;
                status.targets[i].error_code = @errorName(err);
            };
        } else if (application == .zed or application == .equibop or application == .starship) {
            try guard.begin(cancel);
            defer guard.end();
            install(a, config, state, application, &.{}, cancel, false) catch |err| {
                status.targets[i].state = if (err == error.ProfileOwnershipConflict) .conflict else .failed;
                status.targets[i].error_code = @errorName(err);
            };
        }
        switch (status.targets[i].state) {
            .failed, .conflict, .unavailable, .unsupported => {},
            else => status.targets[i].applied_generation = guard.generation,
        }
    }
    return status;
}
test "application ownership preserves edits, restores absence and recovers pending writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.dupeZ(u8, "/tmp/pearl-profile-owned-XXXXXX");
    try std.testing.expect(mkdtemp(root) != null);
    defer @import("install.zig").removeTree(a, root) catch {};
    const state = try std.fmt.allocPrintSentinel(a, "{s}/state", .{root}, 0);
    try io.mkdir(state);
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const name = "pearl-original-theme.json";
    try install(a, root, state, .zed, &.{.{ .name = name, .bytes = "first" }}, cancel, false);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/zed/themes/{s}", .{ root, name }, 0);
    try std.testing.expectEqualStrings("first", (try io.read(a, path, 131072, cancel)).bytes);
    try io.atomic(path, "user edit", false);
    try std.testing.expectError(error.ProfileOwnershipConflict, install(a, root, state, .zed, &.{}, cancel, false));
    try std.testing.expectEqualStrings("user edit", (try io.read(a, path, 131072, cancel)).bytes);
    try io.atomic(path, "first", false);
    try install(a, root, state, .zed, &.{}, cancel, false);
    try std.testing.expect((try io.read(a, path, 131072, cancel)).missing);
    // A process died after publishing the new bytes but before recording success.
    try io.atomic(path, "second", true);
    const journal = try std.fmt.allocPrintSentinel(a, "{s}/zed.json", .{state}, 0);
    try ledgerSave(a, journal, &.{.{ .name = name, .last = &model.hash("first"), .next = &model.hash("second"), .pending = true }});
    try install(a, root, state, .zed, &.{}, cancel, false);
    try std.testing.expect((try io.read(a, path, 131072, cancel)).missing);
}

test "runtime colors bind to committed settings and survive snapshot pruning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.dupeZ(u8, "/tmp/pearl-profile-runtime-XXXXXX");
    try std.testing.expect(mkdtemp(root) != null);
    defer @import("install.zig").removeTree(a, root) catch {};
    const original: provider.Snapshot = .{ .render_json = "original" };
    const digest = try save(a, root, original);
    var prefs: @import("../config/preferences.zig").Preferences = .{};
    prefs.matugen.enabled = true;
    prefs.matugen.snapshot_digest = digest;
    prefs.matugen.colors.source = .wallpaper;
    prefs.wallpaper.path = "/wallpaper.png";
    var runtime = original;
    runtime.render_json = "latest colors";
    _ = try save(a, root, runtime);
    try saveRuntime(a, root, prefs, runtime);
    try prune(a, root, &.{digest});
    try std.testing.expectEqualStrings("latest colors", (try loadRuntime(a, root, prefs)).?.render_json.?);
    try std.testing.expectEqualStrings("original", (try load(a, root, digest)).render_json.?);
    prefs.wallpaper.path = "/different.png";
    try std.testing.expect((try loadRuntime(a, root, prefs)) == null);
    prefs.wallpaper.path = "/wallpaper.png";
    prefs.matugen.colors.source = .seed;
    try std.testing.expect((try loadRuntime(a, root, prefs)) == null);
    const legacy = try model.parse(provider.Snapshot, a, "{\"schema_version\":1,\"render_json\":\"legacy\"}", max_snapshot);
    try validateSnapshot(legacy);
    try std.testing.expectEqualStrings("", legacy.selection_key);
}
test "Matugen full JSON renders exact colors through private config and caches templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.dupeZ(u8, "/tmp/pearl-profile-render-XXXXXX");
    try std.testing.expect(mkdtemp(root) != null);
    defer @import("install.zig").removeTree(a, root) catch {};
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const descriptor: profiles.Descriptor = .{ .schema_version = 1, .id = "original.zed", .application = .zed, .adapter = .zed, .name = "Original", .author = "Pearl", .license = "CC0-1.0", .source = "https://example.org/original", .asset_version = "1.0.0", .variants = &.{ .dark, .light }, .templates = &.{.{ .path = "zed.in", .output = "theme.json" }} };
    const captured: provider.Captured = .{ .application = .zed, .id = descriptor.id, .descriptor = descriptor, .templates = &.{.{ .path = "theme.json", .bytes = "{\"themes\":[{\"name\":\"Pearl test\",\"appearance\":\"dark\",\"style\":{\"background\":\"{{colors.surface.default.hex}}\",\"accent\":\"{{colors.primary.default.hex}}\"}}]}" }} };
    const snapshot: provider.Snapshot = .{ .render_json = @embedFile("matugen_fixture"), .profiles = &.{captured} };
    const expected = try @import("theme.zig").matugenPalette(a, snapshot.render_json.?, "dark");
    const result = try render(a, captured, snapshot, root, cancel);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(std.mem.indexOf(u8, result[0].bytes, expected.surface) != null);
    try std.testing.expect(std.mem.indexOf(u8, result[0].bytes, expected.primary) != null);
    try std.testing.expectEqualStrings(result[0].bytes, (try render(a, captured, snapshot, root, cancel))[0].bytes);
    var light_snapshot = snapshot;
    light_snapshot.variant = .light;
    const light = try render(a, captured, light_snapshot, root, cancel);
    const expected_light = try @import("theme.zig").matugenPalette(a, snapshot.render_json.?, "light");
    try std.testing.expect(std.mem.indexOf(u8, light[0].bytes, expected_light.surface) != null);
    const digest = try save(a, root, snapshot);
    const loaded = try load(a, root, digest);
    try std.testing.expectEqualStrings(captured.templates[0].bytes, loaded.profiles[0].templates[0].bytes);
}

test "all attributed Seafoam templates render supported variants and Starship review preserves backups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.dupeZ(u8, "/tmp/pearl-profile-fixtures-XXXXXX");
    try std.testing.expect(mkdtemp(root) != null);
    _ = glib.setenv("XDG_CACHE_HOME", root, 1);
    _ = glib.unsetenv("STARSHIP_CONFIG");
    defer @import("install.zig").removeTree(a, root) catch {};
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    for (std.enums.values(profiles.Application)) |application| {
        const prefix = try std.fmt.allocPrint(a, "themes/profiles/seafoam.{s}", .{@tagName(application)});
        const manifest = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/profile.json", .{prefix}, 0), 16384, cancel);
        const descriptor = try model.parse(profiles.Descriptor, a, manifest.bytes, 16384);
        try descriptor.validate();
        const file = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ prefix, descriptor.templates[0].path }, 0), 131072, cancel);
        const captured: provider.Captured = .{ .application = application, .id = descriptor.id, .descriptor = descriptor, .templates = &.{.{ .path = descriptor.templates[0].output, .bytes = file.bytes }} };
        for (descriptor.variants) |variant| {
            const snapshot: provider.Snapshot = .{ .profiles = &.{captured}, .render_json = @embedFile("matugen_fixture"), .variant = if (variant == .dark) .dark else .light };
            const output = render(a, captured, snapshot, root, cancel) catch |err| {
                std.debug.print("profile {s} {s}: {s}\n", .{ @tagName(application), @tagName(variant), @errorName(err) });
                return err;
            };
            try std.testing.expect(output[0].bytes.len > 100);
            if (application == .starship and variant == .dark) {
                const path = try std.fmt.allocPrintSentinel(a, "{s}/starship.toml", .{root}, 0);
                try io.atomic(path, "# original user configuration\n", true);
                const review = try reviewStarship(a, root, snapshot, cancel);
                try std.testing.expectEqualStrings("# original user configuration\n", review.current);
                try io.atomic(path, "# changed after review\n", false);
                try std.testing.expectError(error.ProfileReviewChanged, installStarship(a, root, snapshot, review.digest, cancel));
                const refreshed = try reviewStarship(a, root, snapshot, cancel);
                try installStarship(a, root, snapshot, refreshed.digest, cancel);
                try std.testing.expectEqualStrings(refreshed.proposed, (try io.read(a, path, 131072, cancel)).bytes);
                _ = try reconcile(a, root, false, .{}, cancel);
                try std.testing.expectEqualStrings("# changed after review\n", (try io.read(a, path, 131072, cancel)).bytes);
            }
        }
    }
}

/// Explicit author/CI verification. Renders data in isolated temporary storage;
/// no adapter installation, user configuration, contributed command or hook.
pub fn verifyPackage(a: std.mem.Allocator, path: [:0]const u8, output_directory: []const u8, cancel: *gio.Cancellable) ![]const u8 {
    const package = try @import("package.zig").load(a, path);
    if (output_directory.len > 0) {
        if (!std.fs.path.isAbsolute(output_directory)) return error.AbsolutePublicationPathRequired;
        if (c.mkdir(try a.dupeZ(u8, output_directory), 0o700) != 0) return error.PublicationOutputExists;
    }
    const scratch = try a.dupeZ(u8, "/tmp/pearl-profile-check-XXXXXX");
    if (mkdtemp(scratch) == null) return error.ProfileStagingFailed;
    defer @import("install.zig").removeTree(a, scratch) catch {};
    const Check = struct { profile: []const u8, variant: []const u8, sha256: []const u8 };
    var checks: std.ArrayList(Check) = .empty;
    for (package.profiles) |descriptor| {
        var templates: std.ArrayList(@import("package.zig").File) = .empty;
        for (descriptor.templates) |template| try templates.append(a, .{ .path = template.output, .bytes = try package.asset(template.path) });
        const captured: provider.Captured = .{ .id = descriptor.id, .application = descriptor.application, .descriptor = descriptor, .templates = templates.items };
        for (descriptor.variants) |variant| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            var input: ?[]const u8 = null;
            if (package.manifest.render_data) |data| if (if (variant == .dark) data.dark else data.light) |source| {
                input = try package.asset(source);
            };
            if (input == null) {
                var p: @import("../config/preferences.zig").Preferences = .{};
                p.theme.variant = if (variant == .dark) .dark else .light;
                p.theme.source = .seed;
                var hit = false;
                input = (try @import("generator.zig").full(a, p, null, scratch, cancel, &hit)).json;
            }
            const output = try render(a, captured, .{ .render_json = input, .variant = if (variant == .dark) .dark else .light }, scratch, cancel);
            if (output_directory.len > 0) {
                const directory = try std.fmt.allocPrintSentinel(a, "{s}/{s}/{s}", .{ output_directory, descriptor.id, @tagName(variant) }, 0);
                const fd = try safe.directory(a, directory, true);
                defer _ = c.close(fd);
                for (output) |file| try io.atomic(try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, file.name }, 0), file.bytes, true);
            }
            try checks.append(a, .{ .profile = descriptor.id, .variant = @tagName(variant), .sha256 = try a.dupe(u8, &model.hash(try std.json.Stringify.valueAlloc(a, output, .{}))) });
        }
    }
    return std.json.Stringify.valueAlloc(a, .{ .package = package.manifest.id, .checks = checks.items }, .{});
}
