//! Pure, bounded LSP response models. No commands, links, markup, or edits execute here.
//! parse(kind, allocator, result, snapshot_text, encoding) returns move-only Owned(T).
//! All slices (including opaque JSON data) survive destruction of the input DOM.
//! Treat all result fields/opaque JSON as immutable; deinit the owner exactly once,
//! never individual fields or embedded JSON containers. Inputs should normally come from protocol.parseMessage
//! (which also rejects duplicate object keys). Unknown extension fields are ignored
//! after bounded DOM validation. Limits reject, never silently truncate responses.
//!
//! Presentation strings are sanitized PLAIN TEXT: Markdown/HTML are shown literally,
//! never interpreted. Use a text-only widget; escapeMarkup is provided for adapters
//! that cannot avoid a markup widget. Insertion text is never presentation-sanitized.
//! Remote locations retain protocol ranges: validate against the destination snapshot
//! using Location.byteRange before navigation. The supplied snapshot is only used for
//! ranges belonging to the requested document. Controllers must bind every response
//! to its request revision; Diagnostics.version is metadata, not a freshness check.
//! Completion/inlay edits require edits.validateReplacements after selecting the
//! primary range, plus the same revision-checked transaction used by workspace edits.
//! No capabilities are advertised here.
const std = @import("std");
pub const positions = @import("positions.zig");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const Encoding = positions.Encoding;
pub const Range = positions.Range;
pub const ByteRange = positions.ByteRange;
pub const max_items = 512;
pub const max_large_items = 2048;
pub const max_text_bytes = 16 * 1024 * 1024;
/// Aggregate copied/expanded string payload; metadata is separately node-bounded.
pub const max_output_bytes = 16 * 1024 * 1024;
pub const max_token_integers = max_large_items * 5;

pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn validateText(text: []const u8) !void {
    if (text.len > max_text_bytes) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
}

/// Also bounds hand-built DOMs, extension data, recursion, and aggregate allocation.
/// This cannot detect duplicate keys already discarded by the JSON DOM producer.
pub fn validateJson(value: Value) !void {
    var bytes: usize = protocol.max_message_bytes;
    var nodes: usize = 65536;
    try checkJson(value, 0, &bytes, &nodes);
}
fn checkJson(v: Value, depth: usize, bytes: *usize, nodes: *usize) anyerror!void {
    if (depth > protocol.max_json_depth or nodes.* == 0) return error.LimitExceeded;
    nodes.* -= 1;
    switch (v) {
        .string, .number_string => |s| {
            try validateText(s);
            if (s.len > bytes.*) return error.LimitExceeded;
            bytes.* -= s.len;
        },
        .array => |items| {
            if (items.items.len > max_token_integers) return error.LimitExceeded;
            for (items.items) |item| try checkJson(item, depth + 1, bytes, nodes);
        },
        .object => |obj| {
            if (obj.count() > max_large_items) return error.LimitExceeded;
            var it = obj.iterator();
            while (it.next()) |entry| {
                try checkJson(.{ .string = entry.key_ptr.* }, depth + 1, bytes, nodes);
                try checkJson(entry.value_ptr.*, depth + 1, bytes, nodes);
            }
        },
        .float => |n| if (!std.math.isFinite(n)) return error.InvalidShape,
        else => {},
    }
}
pub fn object(v: Value) !void {
    if (v != .object) return error.InvalidShape;
}
pub fn field(v: Value, name: []const u8) ?Value {
    return protocol.field(v, name);
}
pub fn required(v: Value, name: []const u8) !Value {
    try object(v);
    return field(v, name) orelse error.MissingField;
}
pub fn string(v: Value) ![]const u8 {
    if (v != .string) return error.InvalidShape;
    try validateText(v.string);
    return v.string;
}
pub fn integer(v: Value) !i64 {
    if (v != .integer) return error.InvalidShape;
    return v.integer;
}
pub fn uint(v: Value) !u32 {
    const n = try integer(v);
    // LSP uinteger is 31-bit, not the full range of u32.
    if (n < 0 or n > 0x7fffffff) return error.OutOfRange;
    return @intCast(n);
}
pub fn version(v: Value) !?i32 {
    if (v == .null) return null;
    return std.math.cast(i32, try integer(v)) orelse error.OutOfRange;
}
pub fn boolean(v: Value) !bool {
    return if (v == .bool) v.bool else error.InvalidShape;
}
pub fn optionalBool(v: Value, key: []const u8, default: bool) !bool {
    return if (field(v, key)) |b| try boolean(b) else default;
}
pub fn array(v: Value, limit: usize) ![]const Value {
    if (v != .array) return error.InvalidShape;
    if (v.array.items.len > limit) return error.LimitExceeded;
    return v.array.items;
}
pub fn position(v: Value) !positions.Position {
    return .{ .line = try uint(try required(v, "line")), .character = try uint(try required(v, "character")) };
}
fn before(a: positions.Position, b: positions.Position) bool {
    return a.line < b.line or (a.line == b.line and a.character < b.character);
}
pub fn range(v: Value) !Range {
    const result: Range = .{ .start = try position(try required(v, "start")), .end = try position(try required(v, "end")) };
    if (before(result.end, result.start)) return error.ReversedRange;
    return result;
}
fn contains(outer: Range, inner: Range) bool {
    return !before(inner.start, outer.start) and !before(outer.end, inner.end);
}

/// Helpers allocate into a CALLER-OWNED ARENA. On error discard that arena.
/// Public so the workspace model can share exactly the same schema checks.
/// Low-level helpers assume validateJson/validateText preflight; entry points do it.
pub const Decoder = struct {
    allocator: Allocator,
    text: []const u8,
    encoding: Encoding,
    output_budget: ?*usize = null,

    pub fn charge(self: Decoder, count: usize) !void {
        if (self.output_budget) |remaining| {
            if (count > remaining.*) return error.LimitExceeded;
            remaining.* -= count;
        }
    }
    pub fn copy(self: Decoder, v: Value) ![]const u8 {
        const s = try string(v);
        try self.charge(s.len);
        return self.allocator.dupe(u8, s);
    }
    /// Validate an absolute URI's scheme without granting permission to open it.
    /// Local file URI/path canonicalization and authorization belong to edits.
    pub fn uriString(self: Decoder, v: Value) ![]const u8 {
        const s = try string(v);
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.InvalidUri;
        if (colon == 0 or !std.ascii.isAlphabetic(s[0])) return error.InvalidUri;
        for (s[1..colon]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return error.InvalidUri;
        for (s) |ch| if (ch <= 0x20 or ch == 0x7f) return error.InvalidUri;
        return self.copy(v);
    }
    pub fn optionalString(self: Decoder, v: Value, key: []const u8) !?[]const u8 {
        return if (field(v, key)) |s| try self.copy(s) else null;
    }
    pub fn display(self: Decoder, v: Value) ![]const u8 {
        const s = try string(v);
        try self.charge(s.len);
        return plainText(self.allocator, s);
    }
    pub fn optionalDisplay(self: Decoder, v: Value, key: []const u8) !?[]const u8 {
        return if (field(v, key)) |s| try self.display(s) else null;
    }
    pub fn bytes(self: Decoder, v: Value) !ByteRange {
        return positions.byteRange(self.text, try range(v), self.encoding);
    }
    pub fn cloneValue(self: Decoder, v: Value) !Value {
        // Roundtrip preserves data without borrowing the caller's DOM. The input
        // was bounded before this call. Both allocations are owned by the arena.
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, v, .{});
        try self.charge(encoded.len);
        const parsed = try std.json.parseFromSlice(Value, self.allocator, encoded, .{ .allocate = .alloc_always });
        return parsed.value;
    }
};

/// Remove terminal controls and bidi overrides; keep newlines/tabs and literal
/// markup. This is plain text, NOT safe input to a markup/HTML interpreter.
pub fn plainText(a: Allocator, text: []const u8) ![]u8 {
    try validateText(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        const n = try std.unicode.utf8ByteSequenceLength(text[i]);
        const cp = try std.unicode.utf8Decode(text[i..][0..n]);
        if (!((cp < 32 and cp != 9 and cp != 10 and cp != 13) or (cp >= 127 and cp <= 159) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)))
            try out.appendSlice(a, text[i..][0..n]);
        i += n;
    }
    return out.toOwnedSlice(a);
}
pub fn escapeMarkup(a: Allocator, text: []const u8) ![]u8 {
    const plain = try plainText(a, text);
    defer a.free(plain);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (plain) |ch| switch (ch) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, ch),
    };
    return out.toOwnedSlice(a);
}

pub const Markup = struct {
    kind: enum { plaintext, markdown, code },
    text: []const u8,
    language: ?[]const u8 = null,
};
fn markup(d: Decoder, v: Value) !Markup {
    if (v == .string) return .{ .kind = .plaintext, .text = try d.display(v) };
    try object(v);
    if (field(v, "kind")) |k| {
        const kind = try string(k);
        return .{ .kind = if (std.mem.eql(u8, kind, "markdown")) .markdown else if (std.mem.eql(u8, kind, "plaintext")) .plaintext else return error.InvalidShape, .text = try d.display(try required(v, "value")) };
    }
    return .{ .kind = .code, .text = try d.display(try required(v, "value")), .language = try d.copy(try required(v, "language")) };
}
fn optionalMarkup(d: Decoder, v: Value, key: []const u8) !?Markup {
    return if (field(v, key)) |m| try markup(d, m) else null;
}

pub const TextEdit = struct {
    range: Range,
    /// If non-null, range is the replace range. Caller MUST explicitly choose
    /// insert vs replace; WorkspaceEdit rejects InsertReplaceEdit entirely.
    insert: ?Range = null,
    new_text: []const u8,
    annotation_id: ?[]const u8 = null,
    pub fn replacement(self: TextEdit, text: []const u8, encoding: Encoding, mode: enum { insert, replace }) !Replacement {
        try validateText(text);
        const r = try positions.byteRange(text, if (mode == .insert) self.insert orelse self.range else self.range, encoding);
        return .{ .start = r.start, .end = r.end, .text = self.new_text };
    }
};
/// Same shape and half-open UTF-8 semantics as editor/transactions.Replacement.
pub const Replacement = struct { start: usize, end: usize, text: []const u8 };
pub fn textEdit(d: Decoder, v: Value, allow_insert_replace: bool, validate_snapshot: bool) !TextEdit {
    try object(v);
    var result: TextEdit = undefined;
    if (field(v, "range")) |r| {
        if (field(v, "insert") != null or field(v, "replace") != null) return error.InvalidShape;
        result = .{ .range = try range(r), .new_text = try d.copy(try required(v, "newText")) };
    } else {
        if (!allow_insert_replace) return error.InvalidShape;
        const insert = try range(try required(v, "insert"));
        const replace = try range(try required(v, "replace"));
        if (insert.start.line != insert.end.line or replace.start.line != replace.end.line or !std.meta.eql(insert.start, replace.start) or !contains(replace, insert)) return error.InvalidRange;
        result = .{ .range = replace, .insert = insert, .new_text = try d.copy(try required(v, "newText")) };
    }
    result.annotation_id = try d.optionalString(v, "annotationId");
    if (validate_snapshot) {
        _ = try positions.byteRange(d.text, result.range, d.encoding);
        if (result.insert) |r| _ = try positions.byteRange(d.text, r, d.encoding);
    }
    return result;
}
fn textEdits(d: Decoder, v: Value) ![]const TextEdit {
    const items = try array(v, max_large_items);
    const out = try d.allocator.alloc(TextEdit, items.len);
    for (items, out) |item, *dest| dest.* = try textEdit(d, item, false, true);
    return out;
}

pub const Command = struct {
    title: []const u8,
    command: []const u8,
    arguments: []const Value = &.{},
};
fn command(d: Decoder, v: Value) !Command {
    var out: Command = .{ .title = try d.display(try required(v, "title")), .command = try d.copy(try required(v, "command")) };
    if (field(v, "arguments")) |args| {
        const items = try array(args, max_items);
        const owned = try d.allocator.alloc(Value, items.len);
        for (items, owned) |item, *dest| dest.* = try d.cloneValue(item);
        out.arguments = owned;
    }
    return out;
}
fn optionalCommand(d: Decoder, v: Value) !?Command {
    return if (field(v, "command")) |c| try command(d, c) else null;
}

/// Safe snippet subset: escaped $, }, backslash; $0/${0}; numeric placeholders
/// with literal defaults, and choices (first choice). Reject variables, mirrors,
/// transforms and nesting rather than inserting raw snippet syntax or guessing.
/// Numbered placeholders without defaults are empty. Repeated nonzero tabstops
/// are rejected because this module does not implement linked editing.
pub fn expandSnippet(a: Allocator, snippet: []const u8) ![]u8 {
    try validateText(snippet);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var seen: [max_items]u32 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < snippet.len) {
        const ch = snippet[i];
        i += 1;
        if (ch == '\\') {
            if (i == snippet.len or std.mem.indexOfScalar(u8, "$}\\", snippet[i]) == null) return error.UnsupportedSnippet;
            try out.append(a, snippet[i]);
            i += 1;
        } else if (ch == '$') {
            const braced = i < snippet.len and snippet[i] == '{';
            if (braced) i += 1;
            const start = i;
            while (i < snippet.len and std.ascii.isDigit(snippet[i])) : (i += 1) {}
            if (i == start) return error.UnsupportedSnippet;
            const id = std.fmt.parseInt(u32, snippet[start..i], 10) catch return error.UnsupportedSnippet;
            if (id != 0) {
                for (seen[0..count]) |old| if (old == id) return error.UnsupportedSnippet;
                if (count == seen.len) return error.LimitExceeded;
                seen[count] = id;
                count += 1;
            }
            if (!braced) continue;
            if (i == snippet.len) return error.UnsupportedSnippet;
            if (snippet[i] == '}') {
                i += 1;
                continue;
            }
            const choice = snippet[i] == '|';
            if (!choice and snippet[i] != ':') return error.UnsupportedSnippet;
            i += 1;
            var first = true;
            var closed = false;
            while (i < snippet.len) {
                const c = snippet[i];
                i += 1;
                if ((!choice and c == '}') or (choice and c == '|' and i < snippet.len and snippet[i] == '}')) {
                    if (choice) i += 1;
                    closed = true;
                    break;
                }
                if (c == '$' or c == '{' or (choice and (c == '|' or c == '}'))) return error.UnsupportedSnippet;
                if (c == '\\') {
                    if (i == snippet.len or std.mem.indexOfScalar(u8, if (choice) "\\,|" else "\\$}", snippet[i]) == null) return error.UnsupportedSnippet;
                    if (first) try out.append(a, snippet[i]);
                    i += 1;
                } else if (choice and c == ',') {
                    first = false;
                } else if (first) try out.append(a, c);
            }
            if (!closed) return error.UnsupportedSnippet;
        } else try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

pub const CompletionLabelDetails = struct { detail: ?[]const u8, description: ?[]const u8 };
pub const CompletionItem = struct {
    label: []const u8,
    label_details: ?CompletionLabelDetails,
    commit_characters: []const []const u8,
    detail: ?[]const u8,
    documentation: ?Markup,
    kind: ?u32,
    sort_text: ?[]const u8,
    filter_text: ?[]const u8,
    insert_text: []const u8,
    was_snippet: bool,
    /// Unsupported snippets remain visible but MUST NOT be accepted.
    insertable: bool = true,
    edit: ?TextEdit,
    additional_edits: []const TextEdit,
    command: ?Command,
    data: ?Value,
    deprecated: bool,
    preselect: bool,
};
pub const Completion = struct { items: []const CompletionItem, is_incomplete: bool };
fn parseCompletion(d: Decoder, v: Value) !Completion {
    if (v == .null) return .{ .items = &.{}, .is_incomplete = false };
    const items = try array(if (v == .array) v else try required(v, "items"), max_items);
    const incomplete = if (v == .array) false else try boolean(try required(v, "isIncomplete"));
    // Defaults change insertion semantics. Do not silently ignore unsupported ones.
    const defaults = if (v == .object) field(v, "itemDefaults") else null;
    if (defaults) |def| {
        try object(def);
        var it = def.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (!std.mem.eql(u8, k, "editRange") and !std.mem.eql(u8, k, "insertTextFormat") and !std.mem.eql(u8, k, "data") and !std.mem.eql(u8, k, "commitCharacters")) return error.UnsupportedCompletionDefaults;
        }
        if (field(def, "commitCharacters")) |chars| try validateStrings(chars);
    }
    // Shared immutable defaults must not be cloned once per item (amplification).
    const default_data = if (defaults) |def| if (field(def, "data")) |data| try d.cloneValue(data) else null else null;
    const default_commits = if (defaults) |def| if (field(def, "commitCharacters")) |chars| try commitCharacters(d, chars) else &.{} else &.{};
    var default_range: ?Range = null;
    var default_insert: ?Range = null;
    if (defaults) |def| {
        if (field(def, "insertTextFormat")) |fmt| _ = try boundedEnum(fmt, 1, 2);
        if (field(def, "editRange")) |r| {
            if (field(r, "replace")) |replace| {
                default_range = try range(replace);
                default_insert = try range(try required(r, "insert"));
                const ir = default_insert.?;
                if (!std.meta.eql(ir.start, default_range.?.start) or ir.start.line != ir.end.line or !contains(default_range.?, ir)) return error.InvalidRange;
                _ = try positions.byteRange(d.text, ir, d.encoding);
            } else default_range = try range(r);
            if (default_range.?.start.line != default_range.?.end.line) return error.InvalidRange;
            _ = try positions.byteRange(d.text, default_range.?, d.encoding);
        }
    }
    const out = try d.allocator.alloc(CompletionItem, items.len);
    for (items, out) |item, *dest| {
        try object(item);
        const raw_label = try string(try required(item, "label"));
        const format = if (field(item, "insertTextFormat") orelse (if (defaults) |def| field(def, "insertTextFormat") else null)) |f| try uint(f) else 1;
        if (format != 1 and format != 2) return error.InvalidShape;
        if (field(item, "insertTextMode")) |m| if (try uint(m) != 1) return error.UnsupportedInsertTextMode;
        var edit: ?TextEdit = if (field(item, "textEdit")) |e| try textEdit(d, e, true, true) else null;
        if (edit) |value| if (value.range.start.line != value.range.end.line or value.annotation_id != null) return error.InvalidRange;
        var insert_text = if (edit) |value| value.new_text else if (field(item, "insertText")) |text| try d.copy(text) else try d.copy(.{ .string = raw_label });
        if (edit == null) if (default_range) |r| {
            if (field(item, "textEditText")) |text| insert_text = try d.copy(text);
            edit = .{ .range = r, .insert = default_insert, .new_text = insert_text };
        };
        var insertable = true;
        if (format == 2) {
            try d.charge(insert_text.len);
            insert_text = expandSnippet(d.allocator, insert_text) catch |err| switch (err) {
                error.UnsupportedSnippet => blk: {
                    insertable = false;
                    break :blk "";
                },
                else => return err,
            };
        }
        if (edit) |*e| e.new_text = insert_text;
        const commits = if (field(item, "commitCharacters")) |chars| try commitCharacters(d, chars) else default_commits;
        const data = if (field(item, "data")) |value| try d.cloneValue(value) else default_data;
        const label_details: ?CompletionLabelDetails = if (field(item, "labelDetails")) |details| blk: {
            try object(details);
            break :blk .{ .detail = try d.optionalDisplay(details, "detail"), .description = try d.optionalDisplay(details, "description") };
        } else null;
        dest.* = .{
            .label = try d.display(.{ .string = raw_label }),
            .label_details = label_details,
            .commit_characters = commits,
            .detail = try d.optionalDisplay(item, "detail"),
            .documentation = try optionalMarkup(d, item, "documentation"),
            .kind = if (field(item, "kind")) |k| try boundedEnum(k, 1, 25) else null,
            .sort_text = try d.optionalString(item, "sortText"),
            .filter_text = try d.optionalString(item, "filterText"),
            .insert_text = insert_text,
            .was_snippet = format == 2,
            .insertable = insertable,
            .edit = edit,
            .additional_edits = if (field(item, "additionalTextEdits")) |e| try textEdits(d, e) else &.{},
            .command = try optionalCommand(d, item),
            .data = data,
            .deprecated = try optionalBool(item, "deprecated", false),
            .preselect = try optionalBool(item, "preselect", false),
        };
        if (field(item, "tags")) |tags| for (try array(tags, max_items)) |tag| {
            if (try uint(tag) != 1) return error.InvalidShape;
            dest.deprecated = true;
        };
    }
    return .{ .items = out, .is_incomplete = incomplete };
}
fn validateStrings(v: Value) !void {
    for (try array(v, max_items)) |s| _ = try string(s);
}
fn commitCharacters(d: Decoder, v: Value) ![]const []const u8 {
    const items = try array(v, max_items);
    const out = try d.allocator.alloc([]const u8, items.len);
    for (items, out) |item, *dest| {
        const s = try string(item);
        if (s.len == 0 or try std.unicode.utf8ByteSequenceLength(s[0]) != s.len) return error.InvalidShape;
        dest.* = try d.copy(item);
    }
    return out;
}
fn boundedEnum(v: Value, min: u32, max: u32) !u32 {
    const n = try uint(v);
    if (n < min or n > max) return error.InvalidShape;
    return n;
}

pub const Hover = struct { contents: []const Markup, range: ?ByteRange };
fn parseHover(d: Decoder, v: Value) !?Hover {
    if (v == .null) return null;
    const contents = try required(v, "contents");
    const items = if (contents == .array) try array(contents, max_items) else &[_]Value{contents};
    const out = try d.allocator.alloc(Markup, items.len);
    for (items, out) |item, *dest| {
        dest.* = try markup(d, item);
        // Legacy Hover MarkedString strings are Markdown, unlike ordinary
        // documentation strings. Both remain inert plain presentation text.
        if (item == .string) dest.kind = .markdown;
    }
    return .{ .contents = out, .range = if (field(v, "range")) |r| try d.bytes(r) else null };
}

/// label_range refers to raw_label, NOT the presentation-sanitized label.
pub const Parameter = struct { label: []const u8, label_range: ?ByteRange, documentation: ?Markup };
pub const Signature = struct { label: []const u8, raw_label: []const u8, documentation: ?Markup, parameters: []const Parameter, active_parameter: ?u32 };
pub const Signatures = struct { signatures: []const Signature, active_signature: ?u32, active_parameter: ?u32 };
fn parseSignatures(d: Decoder, v: Value) !?Signatures {
    if (v == .null) return null;
    const items = try array(try required(v, "signatures"), max_items);
    const out = try d.allocator.alloc(Signature, items.len);
    for (items, out) |item, *dest| {
        // Signature offsets are UTF-16 regardless of negotiated document encoding.
        const label = try d.copy(try required(item, "label"));
        const params = if (field(item, "parameters")) |p| try array(p, max_items) else &.{};
        const owned = try d.allocator.alloc(Parameter, params.len);
        for (params, owned) |param, *p| {
            const l = try required(param, "label");
            var lr: ?ByteRange = null;
            const pl = if (l == .array) blk: {
                const pair = try array(l, 2);
                if (pair.len != 2) return error.InvalidShape;
                // LSP offsets span the entire label, including newlines.
                const start = try utf16Offset(label, try uint(pair[0]));
                const end = try utf16Offset(label, try uint(pair[1]));
                if (end < start) return error.ReversedRange;
                lr = .{ .start = start, .end = end };
                break :blk try d.display(.{ .string = label[start..end] });
            } else try d.display(l);
            p.* = .{ .label = pl, .label_range = lr, .documentation = try optionalMarkup(d, param, "documentation") };
        }
        dest.* = .{ .label = try d.display(.{ .string = label }), .raw_label = label, .documentation = try optionalMarkup(d, item, "documentation"), .parameters = owned, .active_parameter = if (field(item, "activeParameter")) |p| try uint(p) else null };
        if (dest.active_parameter) |p| if (p >= params.len) return error.OutOfRange;
    }
    const active = if (field(v, "activeSignature")) |s| try uint(s) else null;
    const param = if (field(v, "activeParameter")) |p| try uint(p) else null;
    if (active) |s| if (s >= out.len) return error.OutOfRange;
    if (param) |p| if (out.len == 0 or p >= out[active orelse 0].parameters.len) return error.OutOfRange;
    return .{ .signatures = out, .active_signature = active, .active_parameter = param };
}
fn utf16Offset(text: []const u8, units: u32) !usize {
    var i: usize = 0;
    var used: u32 = 0;
    while (used < units) {
        if (i == text.len) return error.OutOfRange;
        const n = try std.unicode.utf8ByteSequenceLength(text[i]);
        const width: u32 = if (n == 4) 2 else 1;
        if (width > units - used) return error.InvalidBoundary;
        used += width;
        i += n;
    }
    return i;
}

pub const Location = struct {
    uri: []const u8,
    range: Range,
    selection_range: ?Range = null,
    origin_range: ?ByteRange = null,
    pub fn byteRange(self: Location, text: []const u8, encoding: Encoding) !ByteRange {
        try validateText(text);
        const enclosing = try positions.byteRange(text, self.range, encoding);
        return if (self.selection_range) |selection| try positions.byteRange(text, selection, encoding) else enclosing;
    }
};
fn location(d: Decoder, v: Value, allow_link: bool) !Location {
    if (field(v, "targetUri")) |u| {
        if (!allow_link or field(v, "uri") != null) return error.InvalidShape;
        const r = try range(try required(v, "targetRange"));
        const selection = try range(try required(v, "targetSelectionRange"));
        if (!contains(r, selection)) return error.InvalidRange;
        return .{ .uri = try d.uriString(u), .range = r, .selection_range = selection, .origin_range = if (field(v, "originSelectionRange")) |o| try d.bytes(o) else null };
    }
    return .{ .uri = try d.uriString(try required(v, "uri")), .range = try range(try required(v, "range")) };
}
fn locations(d: Decoder, v: Value, allow_link: bool) ![]const Location {
    if (v == .null) return &.{};
    if (!allow_link and v != .array) return error.InvalidShape;
    const items = if (v == .array) try array(v, max_large_items) else &[_]Value{v};
    const out = try d.allocator.alloc(Location, items.len);
    for (items, out) |item, *dest| dest.* = try location(d, item, allow_link);
    return out;
}

pub const Symbol = struct {
    name: []const u8,
    kind: u32,
    detail: ?[]const u8 = null,
    container_name: ?[]const u8 = null,
    location: ?Location = null,
    range: ?ByteRange = null,
    selection_range: ?ByteRange = null,
    children: []const Symbol = &.{},
    deprecated: bool = false,
    data: ?Value = null,
    /// WorkspaceSymbol may defer range resolution to workspaceSymbol/resolve.
    unresolved_uri: ?[]const u8 = null,
};
fn symbols(d: Decoder, v: Value, workspace: bool, budget: *usize, depth: usize) anyerror![]const Symbol {
    if (v == .null and depth == 0) return &.{};
    if (depth > 32) return error.LimitExceeded;
    const items = try array(v, max_large_items);
    if (items.len > budget.*) return error.LimitExceeded;
    budget.* -= items.len;
    const out = try d.allocator.alloc(Symbol, items.len);
    for (items, out) |item, *dest| {
        dest.* = .{ .name = try d.display(try required(item, "name")), .kind = try boundedEnum(try required(item, "kind"), 1, 26), .detail = try d.optionalDisplay(item, "detail"), .container_name = try d.optionalDisplay(item, "containerName"), .deprecated = try optionalBool(item, "deprecated", false), .data = if (field(item, "data")) |x| try d.cloneValue(x) else null };
        if (field(item, "tags")) |tags| for (try array(tags, max_items)) |tag| {
            if (try uint(tag) != 1) return error.InvalidShape;
            dest.deprecated = true;
        };
        if (field(item, "location")) |l| {
            if (field(item, "range") != null or field(item, "children") != null) return error.InvalidShape;
            if (workspace and field(l, "range") == null) dest.unresolved_uri = try d.uriString(try required(l, "uri")) else dest.location = try location(d, l, false);
        } else {
            if (workspace) return error.MissingField;
            const r = try range(try required(item, "range"));
            const s = try range(try required(item, "selectionRange"));
            if (!contains(r, s)) return error.InvalidRange;
            dest.range = try positions.byteRange(d.text, r, d.encoding);
            dest.selection_range = try positions.byteRange(d.text, s, d.encoding);
            if (field(item, "children")) |children| {
                dest.children = try symbols(d, children, false, budget, depth + 1);
                for (dest.children) |child| {
                    const cr = child.range orelse return error.InvalidShape;
                    if (cr.start < dest.range.?.start or cr.end > dest.range.?.end) return error.InvalidRange;
                }
            }
        }
    }
    return out;
}

pub const Severity = enum(u8) { unspecified = 0, err = 1, warning = 2, information = 3, hint = 4 };
pub const RelatedDiagnostic = struct { location: Location, message: []const u8 };
pub const Diagnostic = struct {
    range: ByteRange,
    severity: Severity,
    message: []const u8,
    source: ?[]const u8,
    code: ?Value,
    code_description: ?[]const u8,
    related: []const RelatedDiagnostic,
    unnecessary: bool = false,
    deprecated: bool = false,
    data: ?Value,
};
pub const Diagnostics = struct { uri: []const u8, version: ?i32, items: []const Diagnostic };
fn parseDiagnostics(d: Decoder, v: Value) !Diagnostics {
    const items = try array(try required(v, "diagnostics"), max_large_items);
    const out = try d.allocator.alloc(Diagnostic, items.len);
    for (items, out) |item, *dest| {
        const related = if (field(item, "relatedInformation")) |r| try array(r, max_items) else &.{};
        const owned = try d.allocator.alloc(RelatedDiagnostic, related.len);
        for (related, owned) |r, *o| o.* = .{ .location = try location(d, try required(r, "location"), false), .message = try d.display(try required(r, "message")) };
        const code = if (field(item, "code")) |c| blk: {
            if (c != .string and c != .integer) return error.InvalidShape;
            if (c == .integer) _ = try version(c);
            break :blk try d.cloneValue(c);
        } else null;
        dest.* = .{
            .range = try d.bytes(try required(item, "range")),
            .severity = if (field(item, "severity")) |s| @fromBackingInt(@intCast(try boundedEnum(s, 1, 4))) else .unspecified,
            .message = try d.display(try required(item, "message")),
            .source = try d.optionalDisplay(item, "source"),
            .code = code,
            .code_description = if (field(item, "codeDescription")) |c| try d.uriString(try required(c, "href")) else null,
            .related = owned,
            .data = if (field(item, "data")) |x| try d.cloneValue(x) else null,
        };
        if (field(item, "tags")) |tags| for (try array(tags, max_items)) |tag| switch (try uint(tag)) {
            1 => dest.unnecessary = true,
            2 => dest.deprecated = true,
            else => return error.InvalidShape,
        };
    }
    return .{ .uri = try d.uriString(try required(v, "uri")), .version = if (field(v, "version")) |ver| try version(ver) else null, .items = out };
}

pub const InlayLabelPart = struct { value: []const u8, tooltip: ?Markup, location: ?Location, command: ?Command };
pub const InlayHint = struct {
    position: usize,
    label: []const InlayLabelPart,
    kind: ?u32,
    text_edits: []const TextEdit,
    tooltip: ?Markup,
    padding_left: bool,
    padding_right: bool,
    data: ?Value,
};
fn inlayHints(d: Decoder, v: Value) ![]const InlayHint {
    if (v == .null) return &.{};
    const items = try array(v, max_large_items);
    const out = try d.allocator.alloc(InlayHint, items.len);
    for (items, out) |item, *dest| {
        const l = try required(item, "label");
        const parts = if (l == .array) try array(l, max_items) else &[_]Value{l};
        if (parts.len == 0) return error.InvalidShape;
        const labels = try d.allocator.alloc(InlayLabelPart, parts.len);
        for (parts, labels) |part, *label| {
            const value = if (l == .array) try required(part, "value") else part;
            label.* = .{ .value = try d.display(value), .tooltip = if (l == .array) try optionalMarkup(d, part, "tooltip") else null, .location = if (field(part, "location")) |loc| try location(d, loc, false) else null, .command = if (l == .array) try optionalCommand(d, part) else null };
            if (label.value.len == 0) return error.InvalidShape;
        }
        dest.* = .{
            .position = try positions.byteOffset(d.text, try position(try required(item, "position")), d.encoding),
            .label = labels,
            .kind = if (field(item, "kind")) |k| try boundedEnum(k, 1, 2) else null,
            .text_edits = if (field(item, "textEdits")) |e| try textEdits(d, e) else &.{},
            .tooltip = try optionalMarkup(d, item, "tooltip"),
            .padding_left = try optionalBool(item, "paddingLeft", false),
            .padding_right = try optionalBool(item, "paddingRight", false),
            .data = if (field(item, "data")) |x| try d.cloneValue(x) else null,
        };
    }
    return out;
}
pub const CodeLens = struct { range: ByteRange, command: ?Command, data: ?Value };
fn codeLenses(d: Decoder, v: Value) ![]const CodeLens {
    if (v == .null) return &.{};
    const items = try array(v, max_items);
    const out = try d.allocator.alloc(CodeLens, items.len);
    for (items, out) |item, *dest| dest.* = .{ .range = try d.bytes(try required(item, "range")), .command = try optionalCommand(d, item), .data = if (field(item, "data")) |x| try d.cloneValue(x) else null };
    return out;
}
pub const DocumentLink = struct { range: ByteRange, target: ?[]const u8, tooltip: ?[]const u8, data: ?Value };
fn documentLinks(d: Decoder, v: Value) ![]const DocumentLink {
    if (v == .null) return &.{};
    const items = try array(v, max_items);
    const out = try d.allocator.alloc(DocumentLink, items.len);
    for (items, out) |item, *dest| dest.* = .{ .range = try d.bytes(try required(item, "range")), .target = if (field(item, "target")) |target| try d.uriString(target) else null, .tooltip = try d.optionalDisplay(item, "tooltip"), .data = if (field(item, "data")) |x| try d.cloneValue(x) else null };
    return out;
}

pub const Kind = enum { completion, hover, signatures, definitions, references, document_symbols, workspace_symbols, diagnostics, text_edits, inlay_hints, code_lenses, document_links };
pub fn Result(comptime kind: Kind) type {
    return switch (kind) {
        .completion => Completion,
        .hover => ?Hover,
        .signatures => ?Signatures,
        .definitions, .references => []const Location,
        .document_symbols, .workspace_symbols => []const Symbol,
        .diagnostics => Diagnostics,
        .text_edits => []const TextEdit,
        .inlay_hints => []const InlayHint,
        .code_lenses => []const CodeLens,
        .document_links => []const DocumentLink,
    };
}
pub fn parse(comptime kind: Kind, allocator: Allocator, value: Value, text: []const u8, encoding: Encoding) !Owned(Result(kind)) {
    try validateJson(value);
    try validateText(text);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var output_budget: usize = max_output_bytes;
    const d: Decoder = .{ .allocator = arena.allocator(), .text = text, .encoding = encoding, .output_budget = &output_budget };
    var budget: usize = max_large_items;
    const result = switch (kind) {
        .completion => try parseCompletion(d, value),
        .hover => try parseHover(d, value),
        .signatures => try parseSignatures(d, value),
        .definitions => try locations(d, value, true),
        .references => try locations(d, value, false),
        .document_symbols => try symbols(d, value, false, &budget, 0),
        .workspace_symbols => try symbols(d, value, true, &budget, 0),
        .diagnostics => try parseDiagnostics(d, value),
        .text_edits => if (value == .null) &.{} else try textEdits(d, value),
        .inlay_hints => try inlayHints(d, value),
        .code_lenses => try codeLenses(d, value),
        .document_links => try documentLinks(d, value),
    };
    return .{ .arena = arena, .value = result };
}

pub const Legend = struct { token_types: []const []const u8, token_modifiers: []const []const u8 };
pub const SemanticToken = struct { range: ByteRange, token_type: u32, modifiers: u32 };
pub const SemanticTokens = struct { result_id: ?[]const u8, data: []const u32, tokens: []const SemanticToken };
/// prior is the data for the exact previousResultId used by the request, not an
/// arbitrary cached result. Controller must also bind responses to request revision
/// and legend. Delta edits use offsets in the ORIGINAL integer array, not tokens.
/// Multiline and overlapping tokens are deliberately unsupported (advertise false).
pub fn parseSemanticTokens(allocator: Allocator, value: Value, text: []const u8, encoding: Encoding, legend: Legend, prior: ?SemanticTokens) !Owned(SemanticTokens) {
    try validateJson(value);
    try validateText(text);
    if (legend.token_types.len > max_items or legend.token_modifiers.len > 31) return error.LimitExceeded;
    for (legend.token_types) |name| try validateText(name);
    for (legend.token_modifiers) |name| try validateText(name);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var output_budget: usize = max_output_bytes;
    const d: Decoder = .{ .allocator = a, .text = text, .encoding = encoding, .output_budget = &output_budget };
    if (value == .null) return .{ .arena = arena, .value = .{ .result_id = null, .data = &.{}, .tokens = &.{} } };
    try object(value);
    var data: std.ArrayList(u32) = .empty;
    if (field(value, "data")) |raw| {
        if (field(value, "edits") != null) return error.InvalidShape;
        for (try array(raw, max_token_integers)) |n| try data.append(a, try uint(n));
    } else {
        const old = prior orelse return error.MissingTokenBase;
        if (old.result_id == null) return error.MissingTokenBase;
        if (old.data.len > max_token_integers or old.data.len % 5 != 0) return error.InvalidTokenData;
        const changes = try array(try required(value, "edits"), max_large_items);
        const Delta = struct { start: usize, end: usize, values: []const Value };
        const deltas = try a.alloc(Delta, changes.len);
        for (changes, deltas) |change, *delta| {
            const start = try uint(try required(change, "start"));
            const count = try uint(try required(change, "deleteCount"));
            if (start > old.data.len or count > old.data.len - start) return error.OutOfRange;
            delta.* = .{ .start = start, .end = start + count, .values = if (field(change, "data")) |raw| try array(raw, max_token_integers) else &.{} };
        }
        std.mem.sort(Delta, deltas, {}, struct {
            fn less(_: void, x: Delta, y: Delta) bool {
                return x.start < y.start;
            }
        }.less);
        var cursor: usize = 0;
        var last_start: ?usize = null;
        for (deltas) |delta| {
            if (delta.start < cursor or (last_start != null and last_start.? == delta.start)) return error.OverlappingRanges;
            if (data.items.len + delta.start - cursor + delta.values.len > max_token_integers) return error.LimitExceeded;
            try data.appendSlice(a, old.data[cursor..delta.start]);
            for (delta.values) |n| try data.append(a, try uint(n));
            cursor = delta.end;
            last_start = delta.start;
        }
        if (data.items.len + old.data.len - cursor > max_token_integers) return error.LimitExceeded;
        try data.appendSlice(a, old.data[cursor..]);
    }
    if (data.items.len % 5 != 0) return error.InvalidTokenData;
    const tokens = try a.alloc(SemanticToken, data.items.len / 5);
    var line: u32 = 0;
    var column: u32 = 0;
    var last_end: usize = 0;
    for (tokens, 0..) |*token, i| {
        const p = data.items[i * 5 ..][0..5];
        line = std.math.add(u32, line, p[0]) catch return error.OutOfRange;
        column = if (p[0] == 0) std.math.add(u32, column, p[1]) catch return error.OutOfRange else p[1];
        const end = std.math.add(u32, column, p[2]) catch return error.OutOfRange;
        if (line > 0x7fffffff or end > 0x7fffffff or p[2] == 0 or p[3] >= legend.token_types.len or (p[4] >> @as(u5, @intCast(legend.token_modifiers.len))) != 0) return error.InvalidTokenData;
        const r = try positions.byteRange(text, .{ .start = .{ .line = line, .character = column }, .end = .{ .line = line, .character = end } }, encoding);
        if (i != 0 and r.start < last_end) return error.OverlappingRanges;
        token.* = .{ .range = r, .token_type = p[3], .modifiers = p[4] };
        last_end = r.end;
    }
    return .{ .arena = arena, .value = .{ .result_id = try d.optionalString(value, "resultId"), .data = data.items, .tokens = tokens } };
}
