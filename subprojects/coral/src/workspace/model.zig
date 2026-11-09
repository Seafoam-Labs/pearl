//! First M2 workspace snapshot: owned roots, routing identity and restricted trust.
//! No tree scan, mkdir, settings execution or persistent machine state. Building
//! and resolving file ownership perform synchronous metadata I/O; use a worker.
const std = @import("std");
const manifest = @import("manifest.zig");
const fs = @import("manifest_fs.zig");
pub const identity = @import("identity.zig");
pub const Error = fs.Error;

/// Process-local, nonrecycled, distinct from WorkspaceId and independent of names,
/// paths and array positions. Stable for this model's lifetime, not persisted.
pub const RootId = enum(u64) { _ };
var last_root_id = std.atomic.Value(u64).init(0);
fn allocateRootId() RootId {
    var previous = last_root_id.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, previous, 1) catch @panic("Root IDs exhausted");
        previous = last_root_id.cmpxchgWeak(previous, next, .monotonic, .monotonic) orelse return @fromBackingInt(@intCast(next));
    }
}

/// Machine-owned policy, never decoded from workspace data. There is intentionally
/// no trusted state or promotion API until the machine-policy owner is integrated.
pub const Trust = enum { restricted };
pub const Availability = enum { available, missing, not_directory, permission_denied, symlink_loop, io };
pub const Root = struct {
    id: RootId,
    display_name: []const u8,
    /// Absolute requested spelling, with relative roots joined to manifest parent.
    /// Dot/dot-dot are deliberately NOT collapsed across possible symlinks.
    lexical_path: []const u8,
    /// Present only for an available directory. No invented identity for offline roots.
    canonical_path: ?[]const u8,
    availability: Availability,
};

/// Single-owner, move-only model. Treat roots/strings/trust as read-only. Scope
/// belongs to this model, not a second App owner. Borrowed root pointers remain
/// valid until deinit(). Availability is a snapshot; refresh is deferred in M2.
pub const Model = struct {
    allocator: std.mem.Allocator,
    scope: identity.Scope,
    trust: Trust = .restricted,
    roots: []const Root,
    manifest_path: ?[]const u8,
    /// Owned immutable final-hide patterns, applied independently to every root.
    exclude: []const []const u8 = &.{},

    /// Native absolute folder path; missing/offline/non-directory targets are
    /// retained unavailable, not created. Input storage is never borrowed.
    pub fn fromFolder(allocator: std.mem.Allocator, path: []const u8) Error!Model {
        try fs.absolutePath(path);
        return build(allocator, null, &.{.{ .path = path }}, &.{});
    }

    /// Read an existing regular manifest through a checked, nonblocking descriptor.
    pub fn fromManifest(allocator: std.mem.Allocator, path: []const u8) Error!Model {
        const bytes = try fs.read(allocator, path);
        defer allocator.free(bytes);
        return fromManifestBytes(allocator, path, bytes);
    }

    /// For an already acquired manifest snapshot. Does not read the manifest;
    /// still resolves root metadata. path must be the absolute manifest spelling.
    pub fn fromManifestBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) Error!Model {
        try fs.absolutePath(path);
        if (path[path.len - 1] == '/') return error.InvalidSchema;
        var parsed = try manifest.parse(allocator, bytes);
        defer parsed.deinit();
        return build(allocator, path, parsed.roots, parsed.exclude);
    }

    pub fn deinit(self: *Model) void {
        self.scope.close();
        for (self.roots) |root| freeRoot(self.allocator, root);
        self.allocator.free(self.roots);
        for (self.exclude) |pattern| self.allocator.free(pattern);
        self.allocator.free(self.exclude);
        if (self.manifest_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn rootById(self: *const Model, id: RootId) ?*const Root {
        for (self.roots) |*root| if (root.id == id) return root;
        return null;
    }

    /// Pure longest-component-prefix lookup. Caller supplies a canonical absolute
    /// native path (e.g. open_target result); noncanonical spellings are rejected.
    /// This is routing only, NOT an authorization check for a later file operation.
    pub fn ownerOfCanonicalPath(self: *const Model, path: []const u8) Error!?RootId {
        try fs.absolutePath(path);
        if (path.len > 1) {
            var components = std.mem.splitScalar(u8, path[1..], '/');
            while (components.next()) |part| {
                if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSchema;
            }
        }
        var owner: ?RootId = null;
        var longest: usize = 0;
        for (self.roots) |root| {
            const base = root.canonical_path orelse continue;
            if (base.len <= longest or !std.mem.startsWith(u8, path, base)) continue;
            if (base.len != 1 and path.len != base.len and path[base.len] != '/') continue;
            longest = base.len;
            owner = root.id;
        }
        return owner;
    }

    /// Resolve an existing absolute native file/path, following symlinks, then
    /// route by canonical ownership. Missing files return NotFound, not an owner.
    pub fn ownerOfPath(self: *const Model, path: []const u8) Error!?RootId {
        const resolved = try fs.canonical(self.allocator, path);
        defer self.allocator.free(resolved);
        return self.ownerOfCanonicalPath(resolved);
    }
};

fn build(allocator: std.mem.Allocator, manifest_path: ?[]const u8, specs: []const manifest.Root, excludes: []const []const u8) Error!Model {
    var owned_excludes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_excludes.items) |pattern| allocator.free(pattern);
        owned_excludes.deinit(allocator);
    }
    try owned_excludes.ensureTotalCapacity(allocator, excludes.len);
    for (excludes) |pattern| owned_excludes.appendAssumeCapacity(try allocator.dupe(u8, pattern));
    var roots: std.ArrayList(Root) = .empty;
    errdefer {
        for (roots.items) |root| freeRoot(allocator, root);
        roots.deinit(allocator);
    }
    for (specs) |spec| {
        const root = try makeRoot(allocator, manifest_path, spec);
        errdefer freeRoot(allocator, root);
        // First declared available alias wins, including its display name. Missing
        // declarations stay distinct; there is no canonical identity to merge yet.
        var duplicate = false;
        if (root.canonical_path) |path| {
            for (roots.items) |other| {
                if (other.canonical_path) |other_path| {
                    if (std.mem.eql(u8, path, other_path)) {
                        duplicate = true;
                        break;
                    }
                }
            }
        }
        if (duplicate) {
            freeRoot(allocator, root);
            continue;
        }
        try roots.append(allocator, root);
    }
    const owned_manifest = if (manifest_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (owned_manifest) |path| allocator.free(path);
    const exclude = try owned_excludes.toOwnedSlice(allocator);
    errdefer {
        for (exclude) |pattern| allocator.free(pattern);
        allocator.free(exclude);
    }
    return .{
        .allocator = allocator,
        .exclude = exclude,
        .scope = identity.Scope.init(),
        .roots = try roots.toOwnedSlice(allocator),
        .manifest_path = owned_manifest,
    };
}

fn makeRoot(allocator: std.mem.Allocator, manifest_path: ?[]const u8, spec: manifest.Root) Error!Root {
    const path = if (spec.path[0] == '/') try allocator.dupe(u8, spec.path) else try std.fs.path.join(allocator, &.{ std.fs.path.dirname(manifest_path.?).?, spec.path });
    errdefer allocator.free(path);
    try fs.absolutePath(path);
    var availability: Availability = .available;
    const canonical = fs.directory(allocator, path) catch |err| blk: {
        availability = switch (err) {
            error.NotFound => .missing,
            error.NotDirectory => .not_directory,
            error.PermissionDenied => .permission_denied,
            error.SymlinkLoop => .symlink_loop,
            error.Io => .io,
            else => return err,
        };
        break :blk null;
    };
    errdefer if (canonical) |value| allocator.free(value);
    const fallback = std.fs.path.basename(path);
    const name = try allocator.dupe(u8, spec.name orelse if (fallback.len == 0) "/" else fallback);
    return .{
        .id = allocateRootId(),
        .display_name = name,
        .lexical_path = path,
        .canonical_path = canonical,
        .availability = availability,
    };
}

fn freeRoot(allocator: std.mem.Allocator, root: Root) void {
    allocator.free(root.display_name);
    allocator.free(root.lexical_path);
    if (root.canonical_path) |path| allocator.free(path);
}

test {
    _ = @import("model_test.zig");
    _ = manifest;
}
