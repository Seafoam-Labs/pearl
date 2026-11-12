//! Workspace identity and stale-work invalidation, not an OS sandbox. By user
//! request the workspace consent boundary was removed: Policy is ALWAYS trusted
//! and never refuses a capability. Scope/generation tokens still retire stale
//! work. Filesystem capture and persistence live in trust_fs.zig and must run
//! on workers, without GTK; the stored approvals there no longer gate anything.
const std = @import("std");
const routing = @import("identity.zig");

pub const limits = struct {
    pub const roots = 32;
    pub const path_bytes = 4095;
    pub const records = 256;
    pub const store_bytes = 1024 * 1024;
};
pub const Fingerprint = [32]u8;
pub const PolicyDigest = [32]u8;
pub const State = enum { restricted, trusted };
pub const Capability = enum { lsp, tasks, debug, hooks, extensions, agent_tools, git };
pub const Approval = enum { user_approved };

/// The settings/model owner supplies a domain-separated digest covering ALL
/// effective settings and excludes, including defaults and schema version. This
/// backend never reads .coral/settings.json (its absence is fine), nor a manifest
/// trust flag. Arrays are ordered: changing root order also resets trust.
pub const Input = struct {
    /// Caller spelling of the absolute manifest filename, NOT its realpath.
    /// Relative roots resolve against its lexical parent, even for a symlinked
    /// manifest. Null means folder scope, whose roots must all be absolute.
    manifest_path: ?[]const u8 = null,
    roots: []const []const u8,
    policy_digest: PolicyDigest,
};

/// Move-only immutable worker input. Create before dispatch, then retain until
/// the worker finishes. Never borrow live model/settings slices on a worker.
pub const Inputs = struct {
    arena: std.heap.ArenaAllocator,
    value: Input,

    pub fn init(allocator: std.mem.Allocator, input: Input) !Inputs {
        if (input.roots.len == 0 or input.roots.len > limits.roots) return error.InvalidRoots;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const manifest_path = if (input.manifest_path) |path| blk: {
            try absolutePath(path);
            if (path[path.len - 1] == '/') return error.InvalidPath;
            break :blk try a.dupe(u8, path);
        } else null;
        const roots = try a.alloc([]const u8, input.roots.len);
        for (input.roots, roots) |path, *out| {
            try validPath(path);
            if (manifest_path == null) try absolutePath(path);
            out.* = try a.dupe(u8, path);
        }
        return .{ .arena = arena, .value = .{ .manifest_path = manifest_path, .roots = roots, .policy_digest = input.policy_digest } };
    }

    pub fn deinit(self: *Inputs) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn validPath(path: []const u8) !void {
    if (path.len == 0 or path.len > limits.path_bytes or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
}
pub fn absolutePath(path: []const u8) !void {
    try validPath(path);
    if (path[0] != '/') return error.InvalidPath;
}

/// Supported filesystem birth time, not mutable ctime/mtime. Required even for
/// synthetic identities: there is deliberately no fallback to an inode-only key.
pub const BirthTime = struct {
    seconds: i64,
    nanoseconds: u32,
};

pub const Directory = struct {
    lexical: []const u8,
    canonical: []const u8,
    dev_major: u32,
    dev_minor: u32,
    inode: u64,
    birth_time: BirthTime,
};

/// Move-only capture. No process-local workspace token is persisted or hashed.
/// Retain this to detect scope/policy changes and retire stale work; the
/// fingerprint identifies the exact workspace incarnation, not a consent grant.
pub const Identity = struct {
    arena: std.heap.ArenaAllocator,
    manifest_base: ?Directory,
    roots: []const Directory,
    policy_digest: PolicyDigest,
    fingerprint: Fingerprint,

    pub fn deinit(self: *Identity) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn same(a: Fingerprint, b: Fingerprint) bool {
    return std.mem.eql(u8, &a, &b);
}

const Hash = std.crypto.hash.sha2.Sha256;
fn integer(hash: *Hash, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn field(hash: *Hash, bytes: []const u8) void {
    integer(hash, bytes.len);
    hash.update(bytes);
}
fn directoryHash(hash: *Hash, dir: Directory) void {
    field(hash, dir.lexical);
    field(hash, dir.canonical);
    integer(hash, dir.dev_major);
    integer(hash, dir.dev_minor);
    integer(hash, dir.inode);
    integer(hash, @bitCast(dir.birth_time.seconds));
    integer(hash, dir.birth_time.nanoseconds);
}
pub fn fingerprint(base: ?Directory, roots: []const Directory, digest: PolicyDigest) Fingerprint {
    var hash = Hash.init(.{});
    // v1 approvals bound only dev/inode, which can be recycled after rmdir.
    // Never migrate or match those weaker keys, even for an otherwise same scope.
    field(&hash, "coral.exact-workspace-trust.v2");
    integer(&hash, if (base != null) 1 else 0);
    if (base) |dir| directoryHash(&hash, dir);
    integer(&hash, roots.len);
    for (roots) |dir| directoryHash(&hash, dir);
    field(&hash, &digest);
    return hash.finalResult();
}

pub const Ticket = struct {
    scope: routing.Token,
    generation: u64,
};
pub const Permit = struct {
    ticket: Ticket,
    capability: Capability,
};

/// Main-context owner, not thread-safe. Do not copy a live Policy or directly
/// mutate its fields. Tokens prevent accidental stale dispatch, not hostile Zig
/// code from fabricating a value. The caller must also check its live Scope.
/// Use exactly one Policy per scope token; recreating it requires a fresh token.
///
/// ALWAYS trusted: there is no restricted state, consent, or revocation. issue()
/// succeeds for every capability; validate() only checks scope/generation and
/// capability. begin() invalidates earlier permits before dispatching worker
/// work, and complete() consumes a ticket, so stale results stay rejected. A
/// changed settings/model generation must immediately call begin(), not wait
/// for an outstanding worker. This is a snapshot, not a recursive watcher or
/// per-syscall authorization.
pub const Policy = struct {
    scope: routing.Token,
    generation: u64 = 1,
    /// Kept for UI/diagnostic readers; never assigned anything but .trusted.
    state: State = .trusted,
    exhausted: bool = false,

    pub fn init(scope: routing.Token) Policy {
        return .{ .scope = scope };
    }

    fn invalidate(self: *Policy) void {
        self.generation = std.math.add(u64, self.generation, 1) catch {
            self.exhausted = true;
            return;
        };
    }

    pub fn begin(self: *Policy, scope: routing.Token) !Ticket {
        self.invalidate();
        self.scope = scope;
        if (self.exhausted) return error.GenerationExhausted;
        return .{ .scope = scope, .generation = self.generation };
    }

    pub fn accepts(self: *const Policy, ticket: Ticket) bool {
        return !self.exhausted and self.generation == ticket.generation and sameScope(self.scope, ticket.scope);
    }

    /// Consume a worker ticket. Returns whether it was current; either way it
    /// is retired, so duplicate or late completions cannot apply stale work.
    /// Trust is never a condition: the workspace is always trusted.
    pub fn complete(self: *Policy, ticket: Ticket) bool {
        if (!self.accepts(ticket)) return false;
        self.invalidate();
        return !self.exhausted;
    }

    pub fn issue(self: *const Policy, capability: Capability) !Permit {
        if (self.exhausted) return error.GenerationExhausted;
        return .{ .ticket = .{ .scope = self.scope, .generation = self.generation }, .capability = capability };
    }

    pub fn validate(self: *const Policy, permit: Permit, scope: routing.Token, capability: Capability) bool {
        return sameScope(scope, self.scope) and permit.capability == capability and self.accepts(permit.ticket);
    }
};
fn sameScope(a: routing.Token, b: routing.Token) bool {
    return a.workspace == b.workspace and a.generation == b.generation;
}

/// Strict fixed-width versioned store: header, count, unique fingerprints,
/// SHA-256 checksum. The checksum detects corruption, NOT same-user tampering.
/// Unknown versions, duplicates, truncated/trailing bytes all fail closed.
pub const Records = struct {
    keys: [limits.records]Fingerprint = undefined,
    len: usize = 0,
    const magic = "CORAL-TRUST\x00";
    const header_bytes = magic.len + 4 + 4;

    pub fn contains(self: *const Records, key: Fingerprint) bool {
        for (self.keys[0..self.len]) |other| if (same(key, other)) return true;
        return false;
    }
    pub fn approve(self: *Records, key: Fingerprint) !void {
        if (self.contains(key)) return;
        if (self.len == limits.records) return error.StoreFull;
        self.keys[self.len] = key;
        self.len += 1;
    }
    pub fn revoke(self: *Records, key: Fingerprint) void {
        for (self.keys[0..self.len], 0..) |other, i| {
            if (same(key, other)) {
                self.len -= 1;
                self.keys[i] = self.keys[self.len];
                return;
            }
        }
    }
    pub fn encode(self: *const Records, allocator: std.mem.Allocator) ![]u8 {
        if (self.len > limits.records) return error.TooLarge;
        const bytes = try allocator.alloc(u8, header_bytes + self.len * 32 + 32);
        @memcpy(bytes[0..magic.len], magic);
        std.mem.writeInt(u32, bytes[magic.len..][0..4], 1, .little);
        std.mem.writeInt(u32, bytes[magic.len + 4 ..][0..4], @intCast(self.len), .little);
        for (self.keys[0..self.len], 0..) |key, i| @memcpy(bytes[header_bytes + i * 32 ..][0..32], &key);
        Hash.hash(bytes[0 .. bytes.len - 32], bytes[bytes.len - 32 ..][0..32], .{});
        return bytes;
    }
    pub fn decode(bytes: []const u8) !Records {
        if (bytes.len > limits.store_bytes) return error.TooLarge;
        if (bytes.len < header_bytes + 32 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.CorruptStore;
        if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != 1) return error.UnsupportedVersion;
        const count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
        if (count > limits.records) return error.TooLarge;
        if (bytes.len != header_bytes + @as(usize, count) * 32 + 32) return error.CorruptStore;
        var checksum: Fingerprint = undefined;
        Hash.hash(bytes[0 .. bytes.len - 32], &checksum, .{});
        if (!std.mem.eql(u8, &checksum, bytes[bytes.len - 32 ..])) return error.CorruptStore;
        var out: Records = .{};
        for (0..count) |i| {
            const key = bytes[header_bytes + i * 32 ..][0..32].*;
            if (out.contains(key)) return error.CorruptStore;
            try out.approve(key);
        }
        return out;
    }
};
