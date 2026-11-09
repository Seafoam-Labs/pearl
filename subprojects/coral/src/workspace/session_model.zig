//! Explicit saved session v1, independent of crash-recovery journal versions.
//! Wire: header, SHA-256 hex + newline, one-line workspace JSON + newline,
//! then an unchanged recovery_model encoding (currently v2). The outer checksum
//! covers BOTH the descriptor and recovery bytes. Paths are native bytes/base64;
//! names are UTF-8. No trust decisions, capabilities, or credentials are added.
//! A saved session is the last explicitly accepted checkpoint, not live state.
const std = @import("std");
const recovery = @import("recovery_model.zig");
const a = std.heap.c_allocator;

pub const limits = struct {
    pub const roots = 32;
    pub const path_bytes = 4096;
    pub const name_bytes = 4096;
    // Includes worst-case JSON escaping of all names and base64 of all paths.
    pub const descriptor_bytes = 1024 * 1024;
    pub const session_bytes = prefix_len + descriptor_bytes + 1 + recovery.limits.manifest_bytes;
};
pub const Root = struct { path: []const u8, name: []const u8 };
pub const Workspace = struct {
    source: enum { folder, manifest },
    path: []const u8,
    roots: []const Root,
};
pub const Value = struct {
    snapshot: recovery.Snapshot,
    workspace: ?Workspace = null,
};

/// Immutable deep copy; c_allocator-backed ownership may cross worker threads.
pub const Owned = struct {
    value: Value,
    arena: std.heap.ArenaAllocator,
    snapshot_owner: *recovery.OwnedSnapshot,

    pub fn create(value: Value) !*Owned {
        try validate(value);
        const snapshot = try recovery.OwnedSnapshot.create(value.snapshot);
        errdefer snapshot.deinit();
        return fromSnapshot(snapshot, value.workspace);
    }

    // Consumes snapshot only on success.
    fn fromSnapshot(snapshot: *recovery.OwnedSnapshot, workspace: ?Workspace) !*Owned {
        const self = try a.create(Owned);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var copied = workspace;
        if (workspace) |w| {
            const roots = try alloc.dupe(Root, w.roots);
            for (roots) |*root| {
                root.path = try alloc.dupe(u8, root.path);
                root.name = try alloc.dupe(u8, root.name);
            }
            copied = .{ .source = w.source, .path = try alloc.dupe(u8, w.path), .roots = roots };
        }
        self.* = .{ .value = .{ .snapshot = snapshot.value, .workspace = copied }, .arena = arena, .snapshot_owner = snapshot };
        return self;
    }

    pub fn deinit(self: *Owned) void {
        self.snapshot_owner.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
};

// Workspace descriptors preserve lexical spelling: collapsing dots can change
// meaning across symlinks. These are metadata, not document or storage paths.
fn workspacePath(path: []const u8) !void {
    if (path.len > limits.path_bytes) return error.TooLarge;
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}

fn validateWorkspace(workspace: ?Workspace) !void {
    const w = workspace orelse return;
    try workspacePath(w.path);
    if (w.roots.len > limits.roots) return error.TooLarge;
    for (w.roots) |root| {
        try workspacePath(root.path);
        if (root.name.len > limits.name_bytes) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(root.name)) return error.InvalidWorkspace;
    }
}
fn validate(value: Value) !void {
    try recovery.validate(value.snapshot);
    try validateWorkspace(value.workspace);
    // Recovery validates bounds and excerpt boundaries. Also reject directed
    // selections into continuation bytes, before any later GTK conversion.
    for (value.snapshot.views) |view| {
        for (value.snapshot.documents) |doc| {
            if (doc.id != view.document_id) continue;
            const text = try recovery.presentationText(doc.text, view);
            for ([_]u64{ view.anchor, view.cursor }) |offset| {
                if (offset < text.len and text[@intCast(offset)] & 0xc0 == 0x80) return error.InvalidSnapshot;
            }
        }
    }
}

const WireRoot = struct { path: []const u8, name: []const u8 };
const WireWorkspace = struct { source: @FieldType(Workspace, "source"), path: []const u8, roots: []const WireRoot };
const Descriptor = struct { workspace: ?WireWorkspace };
const magic = "CORAL-SESSION ";
const header = magic ++ "1\n";
const digest_len = 64;
const prefix_len = header.len + digest_len + 1;

fn digest(bytes: []const u8) [digest_len]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn b64(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try alloc.alloc(u8, encoder.calcSize(bytes.len)), bytes);
}
fn pathFromBase64(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(bytes) catch return error.CorruptSession;
    if (len > limits.path_bytes) return error.TooLarge;
    const out = try alloc.alloc(u8, len);
    decoder.decode(out, bytes) catch return error.CorruptSession;
    try workspacePath(out);
    return out;
}

/// Caller frees the result with allocator. This performs no filesystem I/O.
pub fn encode(allocator: std.mem.Allocator, value: Value) ![]u8 {
    try validate(value);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    var workspace: ?WireWorkspace = null;
    if (value.workspace) |w| {
        const roots = try temp.alloc(WireRoot, w.roots.len);
        for (w.roots, roots) |root, *out| out.* = .{ .path = try b64(temp, root.path), .name = root.name };
        workspace = .{ .source = w.source, .path = try b64(temp, w.path), .roots = roots };
    }
    const json = try std.json.Stringify.valueAlloc(temp, Descriptor{ .workspace = workspace }, .{});
    if (json.len > limits.descriptor_bytes) return error.TooLarge;
    const snapshot = try recovery.encode(temp, value.snapshot);
    const out = try allocator.alloc(u8, prefix_len + json.len + 1 + snapshot.len);
    @memcpy(out[0..header.len], header);
    @memcpy(out[prefix_len..][0..json.len], json);
    out[prefix_len + json.len] = '\n';
    @memcpy(out[prefix_len + json.len + 1 ..], snapshot);
    @memcpy(out[header.len..][0..digest_len], &digest(out[prefix_len..]));
    out[prefix_len - 1] = '\n';
    return out;
}

/// Strict, bounded decode. Every failure means the existing file must be kept.
pub fn decode(bytes: []const u8) !*Owned {
    if (bytes.len > limits.session_bytes) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, magic)) return error.CorruptSession;
    if (!std.mem.startsWith(u8, bytes, header)) return error.UnsupportedVersion;
    if (bytes.len < prefix_len or bytes[prefix_len - 1] != '\n') return error.CorruptSession;
    const payload = bytes[prefix_len..];
    if (!std.mem.eql(u8, bytes[header.len..][0..digest_len], &digest(payload))) return error.CorruptSession;
    const end = std.mem.indexOfScalar(u8, payload, '\n') orelse return error.CorruptSession;
    if (end > limits.descriptor_bytes) return error.TooLarge;
    const memory = try a.alloc(u8, limits.descriptor_bytes * 4);
    defer a.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    return decodePayload(fixed.allocator(), payload[0..end], payload[end + 1 ..]) catch |err| switch (err) {
        error.OutOfMemory => error.TooLarge,
        else => err,
    };
}
fn decodePayload(temp: std.mem.Allocator, json: []const u8, snapshot_bytes: []const u8) !*Owned {
    const parsed = std.json.parseFromSlice(Descriptor, temp, json, .{ .allocate = .alloc_always, .max_value_len = limits.descriptor_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.TooLarge,
        else => return error.CorruptSession,
    };
    defer parsed.deinit();
    var workspace: ?Workspace = null;
    if (parsed.value.workspace) |w| {
        if (w.roots.len > limits.roots) return error.TooLarge;
        const roots = try temp.alloc(Root, w.roots.len);
        for (w.roots, roots) |root, *out| out.* = .{ .path = try pathFromBase64(temp, root.path), .name = root.name };
        workspace = .{ .source = w.source, .path = try pathFromBase64(temp, w.path), .roots = roots };
    }
    try validateWorkspace(workspace);
    const snapshot = try recovery.decode(snapshot_bytes);
    errdefer snapshot.deinit();
    try validate(.{ .snapshot = snapshot.value, .workspace = workspace });
    return Owned.fromSnapshot(snapshot, workspace);
}
