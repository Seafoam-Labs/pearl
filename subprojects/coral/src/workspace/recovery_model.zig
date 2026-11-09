//! Version 2 recovery wire format. No GTK or filesystem access.
//! Text, native paths and opaque GIO etags are base64, including embedded NUL in
//! text and non-UTF-8 native path bytes. SHA-256 detects corruption, not tampering
//! by the same Unix user. Version 1 reads as full-document views with zero
//! horizontal scroll. Version 2 adds excerpt bounds and horizontal scroll;
//! older readers reject it rather than silently dropping those fields.
//! Unknown versions/fields are rejected and retained, never guessed at.
const std = @import("std");
const a = std.heap.c_allocator;

pub const limits = struct {
    pub const documents = 128;
    pub const groups = 64;
    pub const views = 256;
    pub const document_bytes = 4 * 1024 * 1024;
    pub const text_bytes = 8 * 1024 * 1024;
    pub const manifest_bytes = 12 * 1024 * 1024;
    pub const metadata_bytes = 4096;
};

pub const Document = struct {
    id: u64,
    /// Metadata only. Restore as a new unsaved buffer by default. Rebinding this
    /// path requires an explicit user decision AND a conditional GIO save using
    /// saved_etag (or conflict UI if it is null). Never blindly refresh the etag.
    path: ?[]const u8 = null,
    text: []const u8,
    dirty: bool = true,
    bom: bool = false,
    newline: enum { lf, crlf, cr, mixed } = .lf,
    revision: u64 = 0,
    saved_etag: ?[]const u8 = null,
};
pub const Group = struct {
    /// Parent-supplied stable layout path; "root", "root/0", etc. No filesystem use.
    path: []const u8,
    split: enum { leaf, horizontal, vertical } = .leaf,
    ratio: u16 = 5000,
    active_view: ?u64 = null,
};
pub const View = struct {
    id: u64,
    document_id: u64,
    group_path: []const u8,
    /// Byte offsets in the presentation text (the excerpt slice when present),
    /// not GTK characters. scroll_line is also relative to that presentation.
    anchor: u64 = 0,
    cursor: u64 = 0,
    scroll_line: u64 = 0,
    /// GTK logical horizontal pixels; finite and nonnegative.
    scroll_x: f64 = 0,
    /// Half-open UTF-8 byte range in the canonical document. Both or neither.
    excerpt_start: ?u64 = null,
    excerpt_end: ?u64 = null,
};
pub const Snapshot = struct {
    documents: []const Document,
    groups: []const Group = &.{},
    views: []const View = &.{},
    active_group: ?[]const u8 = null,
};

/// One independently owned immutable snapshot. create() copies borrowed inputs;
/// it performs no filesystem operations. It rejects unsupported buffers rather
/// than silently omitting them. The UI must surface TooLarge and retain dirty
/// state. Ownership transfers to Store.saveAsync ONLY when that call succeeds.
/// Uses a private c_allocator-backed arena: safe to destroy on a worker thread.
pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,

    pub fn create(value: Snapshot) !*OwnedSnapshot {
        try validate(value);
        const self = try a.create(OwnedSnapshot);
        self.* = .{ .arena = .init(a), .value = undefined };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        const docs = try alloc.dupe(Document, value.documents);
        for (docs) |*doc| {
            doc.text = try alloc.dupe(u8, doc.text);
            if (doc.path) |path| doc.path = try alloc.dupe(u8, path);
            if (doc.saved_etag) |etag| doc.saved_etag = try alloc.dupe(u8, etag);
        }
        const groups = try alloc.dupe(Group, value.groups);
        for (groups) |*group| group.path = try alloc.dupe(u8, group.path);
        const views = try alloc.dupe(View, value.views);
        for (views) |*view| view.group_path = try alloc.dupe(u8, view.group_path);
        self.value = .{
            .documents = docs,
            .groups = groups,
            .views = views,
            .active_group = if (value.active_group) |p| try alloc.dupe(u8, p) else null,
        };
        return self;
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        a.destroy(self);
    }
};

pub fn validate(value: Snapshot) !void {
    if (value.documents.len > limits.documents or value.groups.len > limits.groups or value.views.len > limits.views) return error.TooLarge;
    var total: usize = 0;
    for (value.documents, 0..) |doc, i| {
        if (doc.text.len > limits.document_bytes) return error.TooLarge;
        total += doc.text.len;
        if (total > limits.text_bytes) return error.TooLarge;
        if (doc.path) |path| try nativePath(path);
        if (doc.saved_etag) |etag| {
            if (etag.len > limits.metadata_bytes) return error.TooLarge;
            if (std.mem.indexOfScalar(u8, etag, 0) != null) return error.InvalidSnapshot;
        }
        for (value.documents[0..i]) |other| if (doc.id == other.id) return error.InvalidSnapshot;
    }
    for (value.groups, 0..) |group, i| {
        try groupPath(group.path);
        if (group.ratio > 10000) return error.InvalidSnapshot;
        for (value.groups[0..i]) |other| if (std.mem.eql(u8, group.path, other.path)) return error.InvalidSnapshot;
        if (group.active_view) |id| {
            var found = false;
            for (value.views) |view| {
                if (view.id == id and std.mem.eql(u8, view.group_path, group.path)) found = true;
            }
            if (!found) return error.InvalidSnapshot;
        }
    }
    for (value.views, 0..) |view, i| {
        for (value.views[0..i]) |other| if (view.id == other.id) return error.InvalidSnapshot;
        if (!hasGroup(value, view.group_path)) return error.InvalidSnapshot;
        if (!std.math.isFinite(view.scroll_x) or view.scroll_x < 0 or view.scroll_x > std.math.maxInt(c_int)) return error.InvalidSnapshot;
        if (view.scroll_line > std.math.maxInt(c_int)) return error.InvalidSnapshot;
        var found = false;
        for (value.documents) |doc| {
            if (doc.id == view.document_id) {
                found = true;
                const presented = try presentationText(doc.text, view);
                if (view.anchor > presented.len or view.cursor > presented.len) return error.InvalidSnapshot;
            }
        }
        if (!found) return error.InvalidSnapshot;
    }
    if (value.active_group) |path| if (!hasGroup(value, path)) return error.InvalidSnapshot;
}

/// Bounds-checked presentation slice. Excerpt anchors must be UTF-8 boundaries;
/// complete document bytes remain losslessly serializable, including binary data.
pub fn presentationText(text: []const u8, view: View) ![]const u8 {
    const start = view.excerpt_start orelse {
        if (view.excerpt_end != null) return error.InvalidSnapshot;
        return text;
    };
    const end = view.excerpt_end orelse return error.InvalidSnapshot;
    if (start > end or end > text.len) return error.InvalidSnapshot;
    for ([_]u64{ start, end }) |offset| {
        if (offset < text.len and text[@intCast(offset)] & 0xc0 == 0x80) return error.InvalidSnapshot;
    }
    return text[@intCast(start)..@intCast(end)];
}

fn hasGroup(value: Snapshot, path: []const u8) bool {
    for (value.groups) |group| if (std.mem.eql(u8, path, group.path)) return true;
    return false;
}
fn groupPath(path: []const u8) !void {
    if (path.len == 0 or path.len > 128) return error.InvalidSnapshot;
    for (path) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '/' and ch != '_' and ch != '-') return error.InvalidSnapshot;
}
pub fn nativePath(path: []const u8) !void {
    if (path.len > limits.metadata_bytes) return error.TooLarge;
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidPath;
}

const WireDoc = struct {
    id: u64,
    path: ?[]const u8,
    text: []const u8,
    dirty: bool,
    bom: bool,
    newline: @FieldType(Document, "newline"),
    revision: u64,
    saved_etag: ?[]const u8,
};
const Wire = struct {
    documents: []const WireDoc,
    groups: []const Group,
    views: []const View,
    active_group: ?[]const u8,
};
const ViewV1 = struct {
    id: u64,
    document_id: u64,
    group_path: []const u8,
    anchor: u64 = 0,
    cursor: u64 = 0,
    scroll_line: u64 = 0,
};
const WireV1 = struct {
    documents: []const WireDoc,
    groups: []const Group,
    views: []const ViewV1,
    active_group: ?[]const u8,
};
const magic = "CORAL-RECOVERY ";
const header = magic ++ "2\n";
const legacy_header = magic ++ "1\n";
const digest_len = 64;
const prefix_len = header.len + digest_len + 1;

fn b64(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}
fn unb64(alloc: std.mem.Allocator, bytes: []const u8, cap: usize) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(bytes) catch return error.CorruptManifest;
    if (n > cap) return error.TooLarge;
    const out = try alloc.alloc(u8, n);
    decoder.decode(out, bytes) catch return error.CorruptManifest;
    return out;
}
fn digest(bytes: []const u8) [digest_len]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

/// Caller frees returned bytes with the supplied allocator.
pub fn encode(alloc: std.mem.Allocator, value: Snapshot) ![]u8 {
    try validate(value);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const temp = arena.allocator();
    const docs = try temp.alloc(WireDoc, value.documents.len);
    for (docs, value.documents) |*out, doc| out.* = .{
        .id = doc.id,
        .path = if (doc.path) |p| try b64(temp, p) else null,
        .text = try b64(temp, doc.text),
        .dirty = doc.dirty,
        .bom = doc.bom,
        .newline = doc.newline,
        .revision = doc.revision,
        .saved_etag = if (doc.saved_etag) |e| try b64(temp, e) else null,
    };
    const json = try std.json.Stringify.valueAlloc(temp, Wire{
        .documents = docs,
        .groups = value.groups,
        .views = value.views,
        .active_group = value.active_group,
    }, .{});
    if (json.len > limits.manifest_bytes - prefix_len) return error.TooLarge;
    const out = try alloc.alloc(u8, prefix_len + json.len);
    @memcpy(out[0..header.len], header);
    @memcpy(out[header.len..][0..digest_len], &digest(json));
    out[prefix_len - 1] = '\n';
    @memcpy(out[prefix_len..], json);
    return out;
}

/// Returns a new owned snapshot. On every error the journal must be retained.
/// Parsing has a bounded allocator as well as an input cap, to bound hostile
/// arrays/objects before semantic count validation can run.
pub fn decode(bytes: []const u8) !*OwnedSnapshot {
    if (bytes.len > limits.manifest_bytes) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, magic)) return error.CorruptManifest;
    const legacy = std.mem.startsWith(u8, bytes, legacy_header);
    if (!legacy and !std.mem.startsWith(u8, bytes, header)) return error.UnsupportedVersion;
    if (bytes.len < prefix_len or bytes[prefix_len - 1] != '\n') return error.CorruptManifest;
    const json = bytes[prefix_len..];
    if (!std.mem.eql(u8, bytes[header.len..][0..digest_len], &digest(json))) return error.CorruptManifest;
    return if (legacy) decodeWire(WireV1, json) else decodeWire(Wire, json);
}

fn decodeWire(comptime T: type, json: []const u8) !*OwnedSnapshot {
    const memory = try a.alloc(u8, limits.manifest_bytes * 4);
    defer a.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const temp = fixed.allocator();
    const parsed = std.json.parseFromSlice(T, temp, json, .{ .allocate = .alloc_always, .max_value_len = limits.manifest_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.TooLarge,
        else => return error.CorruptManifest,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.documents.len > limits.documents or wire.groups.len > limits.groups or wire.views.len > limits.views) return error.TooLarge;
    const docs = try temp.alloc(Document, wire.documents.len);
    var total: usize = 0;
    for (docs, wire.documents) |*doc, w| {
        const text = try unb64(temp, w.text, limits.document_bytes);
        total += text.len;
        if (total > limits.text_bytes) return error.TooLarge;
        doc.* = .{
            .id = w.id,
            .path = if (w.path) |p| try unb64(temp, p, limits.metadata_bytes) else null,
            .text = text,
            .dirty = w.dirty,
            .bom = w.bom,
            .newline = w.newline,
            .revision = w.revision,
            .saved_etag = if (w.saved_etag) |e| try unb64(temp, e, limits.metadata_bytes) else null,
        };
    }
    const views = try temp.alloc(View, wire.views.len);
    for (wire.views, views) |view, *out| {
        out.* = if (T == Wire) view else .{ .id = view.id, .document_id = view.document_id, .group_path = view.group_path, .anchor = view.anchor, .cursor = view.cursor, .scroll_line = view.scroll_line };
    }
    return OwnedSnapshot.create(.{ .documents = docs, .groups = wire.groups, .views = views, .active_group = wire.active_group });
}
