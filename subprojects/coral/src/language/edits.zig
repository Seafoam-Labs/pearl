//! Pure WorkspaceEdit/rename parsing and revision-bound planning. No disk or GTK.
//! parse owns a WorkspaceEdit; build owns both its parsed edit and copied snapshots.
//! Both are move-only and must be deinitialized. A Plan is NOT permission to apply.
//!
//! Controller contract:
//! 1. Bind server responses to request snapshots (Resolver.expected_revision).
//! 2. Review annotations/resources and obtain explicit root authorization.
//! 3. Rebuild after authorization, missing-document resolution or resource changes.
//! 4. Call validateForApply with a FRESH resolver immediately before preparing the
//!    existing grouped transaction. Carry each target's id AND exact revision into
//!    that transaction, which must recheck them at commit. Serialize this sequence.
//! No parser can provide isolation against concurrent mutation or filesystem races.
//!
//! Resource operations are typed, ordered, review-only data: collect resources from
//! Plan.resources and pass them to a reviewed workspace-operations controller. A
//! resource-containing plan never passes validateForApply; do not peel off its text
//! edits and apply them independently. No resource-operation or applyEdit capability
//! should be advertised just because this model can parse it. Advertise only what
//! the integrating controller actually executes (including annotation handling).
const std = @import("std");
const f = @import("features.zig");
const uri = @import("uri.zig");
const Allocator = std.mem.Allocator;
const Value = f.Value;
pub const Replacement = f.Replacement;
pub const Encoding = f.Encoding;
pub const max_snapshot_bytes = 64 * 1024 * 1024;

pub const Annotation = struct { id: []const u8, label: []const u8, description: ?[]const u8, needs_confirmation: bool };
pub const CreateOptions = struct { overwrite: bool = false, ignore_if_exists: bool = false };
pub const RenameOptions = CreateOptions;
pub const DeleteOptions = struct { recursive: bool = false, ignore_if_not_exists: bool = false };
pub const Create = struct { uri: []const u8, options: CreateOptions, annotation_id: ?[]const u8 };
pub const Rename = struct { old_uri: []const u8, new_uri: []const u8, options: RenameOptions, annotation_id: ?[]const u8 };
pub const Delete = struct { uri: []const u8, options: DeleteOptions, annotation_id: ?[]const u8 };
pub const ResourceOperation = union(enum) { create: Create, rename: Rename, delete: Delete };
pub const DocumentEdit = struct { uri: []const u8, version: ?i32, edits: []const f.TextEdit };
pub const Operation = union(enum) { text: DocumentEdit, resource: ResourceOperation };
pub const WorkspaceEdit = struct {
    /// documentChanges order is preserved. changes map order is not meaningful.
    operations: []const Operation,
    annotations: []const Annotation,
    pub fn annotation(self: WorkspaceEdit, id: []const u8) ?Annotation {
        for (self.annotations) |a| if (std.mem.eql(u8, a.id, id)) return a;
        return null;
    }
};

fn nonempty(d: f.Decoder, value: Value) ![]const u8 {
    const s = try d.copy(value);
    if (s.len == 0) return error.InvalidShape;
    return s;
}
fn editList(d: f.Decoder, value: Value, budget: *usize, annotated: bool) ![]const f.TextEdit {
    const items = try f.array(value, f.max_large_items);
    if (items.len > budget.*) return error.LimitExceeded;
    budget.* -= items.len;
    const out = try d.allocator.alloc(f.TextEdit, items.len);
    for (items, out) |item, *dest| {
        dest.* = try f.textEdit(d, item, false, false);
        if (!annotated and dest.annotation_id != null) return error.InvalidShape;
        if (f.field(item, "insertTextFormat") != null or f.field(item, "snippet") != null) return error.UnsupportedSnippet;
    }
    return out;
}
fn createOptions(v: Value) !CreateOptions {
    try f.object(v);
    return .{ .overwrite = try f.optionalBool(v, "overwrite", false), .ignore_if_exists = try f.optionalBool(v, "ignoreIfExists", false) };
}
fn resource(d: f.Decoder, v: Value) !ResourceOperation {
    const kind = try f.string(try f.required(v, "kind"));
    const annotation = try d.optionalString(v, "annotationId");
    if (f.field(v, "textDocument") != null or f.field(v, "edits") != null) return error.InvalidShape;
    if (std.mem.eql(u8, kind, "create")) return .{ .create = .{
        .uri = try nonempty(d, try f.required(v, "uri")),
        .annotation_id = annotation,
        .options = if (f.field(v, "options")) |o| try createOptions(o) else .{},
    } };
    if (std.mem.eql(u8, kind, "rename")) return .{ .rename = .{
        .old_uri = try nonempty(d, try f.required(v, "oldUri")),
        .new_uri = try nonempty(d, try f.required(v, "newUri")),
        .annotation_id = annotation,
        .options = if (f.field(v, "options")) |o| try createOptions(o) else .{},
    } };
    if (std.mem.eql(u8, kind, "delete")) {
        var options: DeleteOptions = .{};
        if (f.field(v, "options")) |o| {
            try f.object(o);
            options = .{ .recursive = try f.optionalBool(o, "recursive", false), .ignore_if_not_exists = try f.optionalBool(o, "ignoreIfNotExists", false) };
        }
        return .{ .delete = .{ .uri = try nonempty(d, try f.required(v, "uri")), .annotation_id = annotation, .options = options } };
    }
    return error.UnsupportedResourceOperation;
}
fn resourceAnnotation(r: ResourceOperation) ?[]const u8 {
    return switch (r) {
        inline else => |op| op.annotation_id,
    };
}
fn checkAnnotation(w: WorkspaceEdit, id: ?[]const u8) !void {
    if (id) |key| if (w.annotation(key) == null) return error.UnknownAnnotation;
}
fn decode(d: f.Decoder, value: Value) !WorkspaceEdit {
    // Rename may return null: a successful no-op, not a malformed edit.
    if (value == .null) return .{ .operations = &.{}, .annotations = &.{} };
    try f.object(value);
    var annotations: std.ArrayList(Annotation) = .empty;
    if (f.field(value, "changeAnnotations")) |all| {
        try f.object(all);
        if (all.object.count() > f.max_items) return error.LimitExceeded;
        var it = all.object.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len == 0) return error.InvalidShape;
            const v = entry.value_ptr.*;
            try annotations.append(d.allocator, .{
                .id = try d.allocator.dupe(u8, entry.key_ptr.*),
                .label = try d.display(try f.required(v, "label")),
                .description = try d.optionalDisplay(v, "description"),
                .needs_confirmation = try f.optionalBool(v, "needsConfirmation", false),
            });
        }
    }
    var operations: std.ArrayList(Operation) = .empty;
    var budget: usize = f.max_large_items;
    const changes = f.field(value, "changes");
    const documents = f.field(value, "documentChanges");
    // The protocol permits both fields but gives no ordering between them. Do not
    // silently choose one or combine potentially duplicate edits.
    if (changes != null and documents != null) return error.AmbiguousWorkspaceEdit;
    if (changes) |all| {
        try f.object(all);
        if (all.object.count() > f.max_items) return error.LimitExceeded;
        var it = all.object.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len == 0) return error.InvalidShape;
            try operations.append(d.allocator, .{ .text = .{
                .uri = try d.allocator.dupe(u8, entry.key_ptr.*),
                .version = null,
                .edits = try editList(d, entry.value_ptr.*, &budget, false),
            } });
        }
    }
    if (documents) |all| for (try f.array(all, f.max_items)) |item| {
        try f.object(item);
        if (f.field(item, "kind") != null) {
            try operations.append(d.allocator, .{ .resource = try resource(d, item) });
        } else {
            const doc = try f.required(item, "textDocument");
            try operations.append(d.allocator, .{ .text = .{
                .uri = try nonempty(d, try f.required(doc, "uri")),
                .version = try f.version(try f.required(doc, "version")),
                .edits = try editList(d, try f.required(item, "edits"), &budget, true),
            } });
        }
    };
    const out: WorkspaceEdit = .{ .operations = operations.items, .annotations = annotations.items };
    for (out.operations) |op| switch (op) {
        .text => |t| for (t.edits) |e| try checkAnnotation(out, e.annotation_id),
        .resource => |r| try checkAnnotation(out, resourceAnnotation(r)),
    };
    return out;
}
pub fn parse(allocator: Allocator, value: Value) !f.Owned(WorkspaceEdit) {
    try f.validateJson(value);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const result = try decode(.{ .allocator = arena.allocator(), .text = "", .encoding = .utf16 }, value);
    return .{ .arena = arena, .value = result };
}

/// Only authorized permits text application. Being lexically inside a root is NOT
/// authorization (symlinks, writable policy, trust and filesystem identity matter).
/// The resolver/controller, not URI normalization, decides this state.
pub const Authorization = enum { authorized, needs_authorization, outside_root, denied, unknown_uri };
pub const Snapshot = struct {
    uri: []const u8,
    text: []const u8,
    version: ?i32,
    revision: u64,
    id: u64,
    root_authorization: Authorization,
    /// Request-time revision, if supplied. A mismatch rejects the entire plan.
    /// If omitted, caller must correlate the response with its request independently.
    expected_revision: ?u64 = null,
};
/// Borrowed snapshot remains valid until the next callback; build copies it before
/// calling again. null means unknown URI, NEVER an implicitly authorized new file.
pub const Resolver = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8) anyerror!?Snapshot,
    pub fn get(self: Resolver, canonical_uri: []const u8) !?Snapshot {
        return self.resolve(self.context, canonical_uri);
    }
};
pub const Captured = struct { text: []const u8, version: ?i32, revision: u64, id: u64 };
pub const Target = struct {
    uri: []const u8,
    authorization: Authorization,
    snapshot: ?Captured,
    requested_version: ?i32,
    /// Original protocol edits, including annotation IDs (not sorted).
    edits: []const f.TextEdit,
    /// Sorted, validated byte replacements. Empty when the target is unresolved.
    replacements: []const Replacement,
};
pub const ResourceReview = struct {
    /// Index in WorkspaceEdit.operations preserves order relative to text edits.
    operation_index: usize,
    operation: ResourceOperation,
    source_authorization: Authorization,
    destination_authorization: ?Authorization = null,
    needs_confirmation: bool = true,
};
pub const State = enum { ready, needs_confirmation, blocked, resource_review };
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    workspace: WorkspaceEdit,
    targets: []const Target,
    resources: []const ResourceReview,
    needs_confirmation: bool,
    state: State,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Validates ALL targets and referenced confirmation annotations before the
    /// controller mutates anything. Does not mutate or "approve" this plan. Fresh
    /// root authorization and identity, revision, version AND bytes must match.
    /// Confirmed IDs are explicit user approvals for THIS plan only, not a cache.
    pub fn validateForApply(self: *const Plan, resolver: Resolver, confirmed_ids: []const []const u8) !void {
        if (self.resources.len != 0) return error.ResourceReviewRequired;
        if (confirmed_ids.len > f.max_items) return error.LimitExceeded;
        for (self.targets) |target| {
            const saved = target.snapshot orelse return error.UnknownUri;
            if (target.authorization != .authorized) return error.AuthorizationRequired;
            const fresh = (try resolver.get(target.uri)) orelse return error.UnknownUri;
            // Resolver URIs must be canonical, avoiding allocation during validation.
            if (!std.mem.eql(u8, fresh.uri, target.uri) or fresh.id != saved.id) return error.TargetMismatch;
            if (fresh.root_authorization != .authorized) return error.AuthorizationRequired;
            if (fresh.revision != saved.revision) return error.StaleRevision;
            if (fresh.expected_revision) |expected| if (expected != fresh.revision) return error.StaleRevision;
            if (fresh.version != saved.version) return error.VersionMismatch;
            if (!std.mem.eql(u8, fresh.text, saved.text)) return error.SnapshotMismatch;
            for (target.edits) |edit| if (edit.annotation_id) |id| {
                if (self.workspace.annotation(id).?.needs_confirmation) {
                    var confirmed = false;
                    for (confirmed_ids) |approved| if (std.mem.eql(u8, approved, id)) {
                        confirmed = true;
                        break;
                    };
                    if (!confirmed) return error.ConfirmationRequired;
                }
            };
        }
    }
};

fn canonical(a: Allocator, value: []const u8) ![]const u8 {
    // Strict local file URIs only for edits; remote/custom schemes can be displayed
    // by features but require a different, explicit execution backend.
    const path = try uri.toPath(a, value);
    defer a.free(path);
    return uri.fromPath(a, path);
}
fn less(_: void, x: Replacement, y: Replacement) bool {
    return if (x.start == y.start) x.end < y.end else x.start < y.start;
}
/// Also usable by completion/inlay controllers after selecting insertion mode.
/// Sorts in place; validates all ranges/text against the unmodified snapshot.
pub fn validateReplacements(text: []const u8, replacements: []Replacement) !void {
    try f.validateText(text);
    if (replacements.len > f.max_large_items) return error.LimitExceeded;
    for (replacements) |r| {
        try f.validateText(r.text);
        if (r.start > r.end or r.end > text.len) return error.OutOfRange;
        _ = try f.positions.positionAt(text, r.start, .utf8);
        _ = try f.positions.positionAt(text, r.end, .utf8);
    }
    std.mem.sort(Replacement, replacements, {}, less);
    var last: ?Replacement = null;
    for (replacements) |r| {
        if (last) |p| {
            if (p.start == r.start and (p.start == p.end or r.start == r.end)) return error.AmbiguousInsertion;
            if (r.start < p.end) return error.OverlappingRanges;
        }
        last = r;
    }
    // Bound transient descending-application size, not merely the final length.
    var size = text.len;
    var i = replacements.len;
    while (i != 0) {
        i -= 1;
        const r = replacements[i];
        size -= r.end - r.start;
        size = std.math.add(usize, size, r.text.len) catch return error.LimitExceeded;
        if (size > f.max_text_bytes) return error.LimitExceeded;
    }
}
fn resourceAuth(resolver: Resolver, name: []const u8) !Authorization {
    const snap = (try resolver.get(name)) orelse return .unknown_uri;
    if (!std.mem.eql(u8, snap.uri, name)) return error.TargetMismatch;
    return snap.root_authorization;
}
fn normalizeResource(a: Allocator, r: ResourceOperation) !ResourceOperation {
    return switch (r) {
        .create => |op| .{ .create = .{ .uri = try canonical(a, op.uri), .options = op.options, .annotation_id = op.annotation_id } },
        .rename => |op| .{ .rename = .{ .old_uri = try canonical(a, op.old_uri), .new_uri = try canonical(a, op.new_uri), .options = op.options, .annotation_id = op.annotation_id } },
        .delete => |op| .{ .delete = .{ .uri = try canonical(a, op.uri), .options = op.options, .annotation_id = op.annotation_id } },
    };
}
pub fn build(allocator: Allocator, value: Value, resolver: Resolver, encoding: Encoding) !Plan {
    try f.validateJson(value);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const workspace = try decode(.{ .allocator = a, .text = "", .encoding = encoding }, value);
    var targets: std.ArrayList(Target) = .empty;
    var resources: std.ArrayList(ResourceReview) = .empty;
    var total_bytes: usize = 0;
    var confirmation = false;
    var blocked = false;
    for (workspace.operations, 0..) |op, op_index| switch (op) {
        .text => |doc| {
            const name = try canonical(a, doc.uri);
            // Multiple TextDocumentEdits for one URI can be sequential. Without
            // intermediate snapshots we cannot safely merge them into one base.
            for (targets.items) |old| if (std.mem.eql(u8, old.uri, name)) return error.DuplicateDocumentChange;
            var target: Target = .{ .uri = name, .authorization = .unknown_uri, .snapshot = null, .requested_version = doc.version, .edits = doc.edits, .replacements = &.{} };
            if (try resolver.get(name)) |snapshot| {
                if (!std.mem.eql(u8, snapshot.uri, name)) return error.TargetMismatch;
                try f.validateText(snapshot.text);
                if (snapshot.expected_revision) |expected| if (snapshot.revision != expected) return error.StaleRevision;
                if (doc.version) |v| if (snapshot.version == null or snapshot.version.? != v) return error.VersionMismatch;
                for (targets.items) |old| if (old.snapshot) |s| if (s.id == snapshot.id) return error.TargetMismatch;
                if (snapshot.text.len > max_snapshot_bytes - total_bytes) return error.LimitExceeded;
                total_bytes += snapshot.text.len;
                target.snapshot = .{ .text = try a.dupe(u8, snapshot.text), .version = snapshot.version, .revision = snapshot.revision, .id = snapshot.id };
                target.authorization = snapshot.root_authorization;
                const replacements = try a.alloc(Replacement, doc.edits.len);
                for (doc.edits, replacements) |edit, *r| r.* = try edit.replacement(snapshot.text, encoding, .replace);
                try validateReplacements(snapshot.text, replacements);
                target.replacements = replacements;
            }
            if (target.authorization != .authorized or target.snapshot == null) blocked = true;
            for (doc.edits) |edit| if (edit.annotation_id) |id| {
                if (workspace.annotation(id).?.needs_confirmation) confirmation = true;
            };
            try targets.append(a, target);
        },
        .resource => |r| {
            const normalized = try normalizeResource(a, r);
            var review: ResourceReview = .{ .operation_index = op_index, .operation = normalized, .source_authorization = .unknown_uri };
            switch (normalized) {
                .create => |c| review.source_authorization = try resourceAuth(resolver, c.uri),
                .delete => |c| review.source_authorization = try resourceAuth(resolver, c.uri),
                .rename => |c| {
                    if (std.mem.eql(u8, c.old_uri, c.new_uri)) return error.InvalidResourceOperation;
                    review.source_authorization = try resourceAuth(resolver, c.old_uri);
                    review.destination_authorization = try resourceAuth(resolver, c.new_uri);
                },
            }
            confirmation = true;
            try resources.append(a, review);
        },
    };
    return .{ .arena = arena, .workspace = workspace, .targets = targets.items, .resources = resources.items, .needs_confirmation = confirmation, .state = if (resources.items.len != 0) .resource_review else if (blocked) .blocked else if (confirmation) .needs_confirmation else .ready };
}
