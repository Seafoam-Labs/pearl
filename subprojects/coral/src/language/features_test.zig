//! Standalone: zig test src/language/features_test.zig (Zig 0.17.1, std only).
const std = @import("std");
const t = std.testing;
const a = t.allocator;
const f = @import("features.zig");
const e = @import("edits.zig");
const protocol = @import("protocol.zig");
const r01 = "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}";
const r02 = "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":2}}";
const r23 = "{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":3}}";
const r22 = "{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":2}}";
const edit01 = "{\"range\":" ++ r01 ++ ",\"newText\":\"z\"}";
const edit02 = "{\"range\":" ++ r02 ++ ",\"newText\":\"x\"}";
const edit23 = "{\"range\":" ++ r23 ++ ",\"newText\":\"é\"}";
fn json(bytes: []const u8) !std.json.Parsed(f.Value) {
    return protocol.parseMessage(a, bytes);
}
fn parse(comptime kind: f.Kind, bytes: []const u8, text: []const u8) !f.Owned(f.Result(kind)) {
    var p = try json(bytes);
    defer p.deinit();
    return f.parse(kind, a, p.value, text, .utf16);
}
fn expectParseError(comptime kind: f.Kind, expected: anyerror, bytes: []const u8, text: []const u8) !void {
    try t.expectError(expected, parse(kind, bytes, text));
}

const Fixture = struct {
    text: []const u8 = "😀a\r\nb",
    version: ?i32 = 7,
    revision: u64 = 41,
    expected: ?u64 = 41,
    auth: e.Authorization = .authorized,
    missing: bool = false,
    id: u64 = 1,
    fn resolver(self: *Fixture) e.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
    fn resolve(ctx: *anyopaque, name: []const u8) !?e.Snapshot {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.missing) return null;
        if (std.mem.eql(u8, name, "file:///root/a")) return .{ .uri = name, .text = self.text, .version = self.version, .revision = self.revision, .id = self.id, .root_authorization = self.auth, .expected_revision = self.expected };
        if (std.mem.eql(u8, name, "file:///root/b")) return .{ .uri = name, .text = "éxy", .version = 3, .revision = 15, .id = 2, .root_authorization = .authorized };
        return null;
    }
};
fn plan(bytes: []const u8, fixture: *Fixture) !e.Plan {
    var p = try json(bytes);
    defer p.deinit();
    return e.build(a, p.value, fixture.resolver(), .utf16);
}
const multi_edit = "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":7},\"edits\":[" ++ edit23 ++ "," ++ edit02 ++ "]},{\"textDocument\":{\"uri\":\"file:///root/b\",\"version\":3},\"edits\":[" ++ edit01 ++ "]}]}";

test "completion owns strings and opaque data; safe snippets and insert/replace ranges" {
    var result = try parse(.completion, "{\"isIncomplete\":true,\"items\":[{\"label\":\"f<T>\",\"kind\":3,\"detail\":\"detail\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"**doc** <script>\"},\"insertTextFormat\":2,\"textEdit\":{\"insert\":" ++ r02 ++ ",\"replace\":" ++ "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}}" ++ ",\"newText\":\"f(${1:value}, ${2|a,b|})$0\"},\"additionalTextEdits\":[],\"data\":{\"id\":\"kept\"},\"command\":{\"title\":\"Run\",\"command\":\"not.executed\",\"arguments\":[{\"x\":1}]}}]}", "😀a");
    defer result.deinit();
    const item = result.value.items[0];
    try t.expect(result.value.is_incomplete);
    try t.expect(item.was_snippet and item.insertable);
    try t.expectEqualStrings("f(value, a)", item.insert_text);
    try t.expectEqualStrings("kept", item.data.?.object.get("id").?.string);
    try t.expectEqualStrings("**doc** <script>", item.documentation.?.text);
    const ins = try item.edit.?.replacement("😀a", .utf16, .insert);
    const rep = try item.edit.?.replacement("😀a", .utf16, .replace);
    try t.expectEqual(@as(usize, 4), ins.end);
    try t.expectEqual(@as(usize, 5), rep.end);
    try t.expectEqualStrings("not.executed", item.command.?.command);
}

test "completion defaults and unsupported snippets are never inserted raw" {
    var result = try parse(.completion, "{\"isIncomplete\":false,\"itemDefaults\":{\"editRange\":" ++ r02 ++ ",\"insertTextFormat\":2,\"data\":42},\"items\":[{\"label\":\"label\",\"textEditText\":\"${1:ok}$0\"},{\"label\":\"bad\",\"insertText\":\"$TM_FILENAME\"}]}", "😀");
    defer result.deinit();
    try t.expectEqualStrings("ok", result.value.items[0].edit.?.new_text);
    try t.expectEqual(@as(i64, 42), result.value.items[0].data.?.integer);
    try t.expect(!result.value.items[1].insertable);
    try t.expectEqualStrings("", result.value.items[1].insert_text);
    try expectParseError(.completion, error.UnsupportedCompletionDefaults, "{\"isIncomplete\":false,\"items\":[],\"itemDefaults\":{\"insertTextMode\":2}}", "");
    try expectParseError(.completion, error.InvalidShape, "[{\"label\":\"a\",\"insertTextFormat\":3}]", "");
    try expectParseError(.completion, error.InvalidBoundary, "[{\"label\":\"a\",\"textEdit\":" ++ edit01 ++ "}]", "😀");
}

test "snippet subset escapes choices tabstops and rejects unsafe semantics" {
    const cases = [_]struct { input: []const u8, output: []const u8 }{
        .{ .input = "hello $1$0", .output = "hello " },
        .{ .input = "${1:é} ${2|x\\,y,z|} \\$ \\}", .output = "é x,y $ }" },
        .{ .input = "${0}", .output = "" },
    };
    for (cases) |c| {
        const expanded = try f.expandSnippet(a, c.input);
        defer a.free(expanded);
        try t.expectEqualStrings(c.output, expanded);
    }
    for ([_][]const u8{ "$VAR", "${VAR:x}", "${1:${2:x}}", "${1/a/b/}", "$1 $1", "${1", "${1|x|", "${1:x", "$999999999999999", "\\q" }) |bad|
        try t.expectError(error.UnsupportedSnippet, f.expandSnippet(a, bad));
}

test "hover markup stays inert; plain controls and markup escaping" {
    var hover = try parse(.hover, "{\"contents\":[\"plain\",{\"language\":\"zig\",\"value\":\"<b>code</b>\"},{\"kind\":\"markdown\",\"value\":\"[x](javascript:alert(1))\"}],\"range\":" ++ r02 ++ "}", "😀");
    defer hover.deinit();
    try t.expectEqual(@as(usize, 3), hover.value.?.contents.len);
    try t.expectEqualStrings("<b>code</b>", hover.value.?.contents[1].text);
    try t.expectEqual(@as(usize, 4), hover.value.?.range.?.end);
    const plain = try f.plainText(a, "a\x1b[31m\u{202e}<b>\t\n");
    defer a.free(plain);
    try t.expectEqualStrings("a[31m<b>\t\n", plain);
    const escaped = try f.escapeMarkup(a, "<b>&\"'</b>");
    defer a.free(escaped);
    try t.expectEqualStrings("&lt;b&gt;&amp;&quot;&apos;&lt;/b&gt;", escaped);
    try expectParseError(.hover, error.InvalidShape, "{\"contents\":{\"kind\":\"html\",\"value\":\"x\"}}", "");
}

test "signatures UTF16 tuple labels and active indices" {
    var signatures = try parse(.signatures, "{\"signatures\":[{\"label\":\"f(😀, x)\",\"parameters\":[{\"label\":[2,4],\"documentation\":\"emoji\"},{\"label\":\"x\"}],\"activeParameter\":0}],\"activeSignature\":0,\"activeParameter\":1}", "");
    defer signatures.deinit();
    try t.expectEqualStrings("😀", signatures.value.?.signatures[0].parameters[0].label);
    try t.expectEqual(@as(usize, 6), signatures.value.?.signatures[0].parameters[0].label_range.?.end);
    try expectParseError(.signatures, error.InvalidBoundary, "{\"signatures\":[{\"label\":\"😀\",\"parameters\":[{\"label\":[0,1]}]}]}", "");
    try expectParseError(.signatures, error.OutOfRange, "{\"signatures\":[],\"activeSignature\":0}", "");
}

test "definition locations links and references retain remote ranges" {
    var definitions = try parse(.definitions, "[{\"targetUri\":\"file:///remote\",\"targetRange\":" ++ r02 ++ ",\"targetSelectionRange\":" ++ r02 ++ ",\"originSelectionRange\":" ++ r02 ++ "}]", "😀");
    defer definitions.deinit();
    try t.expectEqual(@as(usize, 4), (try definitions.value[0].byteRange("😀", .utf16)).end);
    try t.expectEqual(@as(usize, 4), definitions.value[0].origin_range.?.end);
    var single = try parse(.definitions, "{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "}", "");
    defer single.deinit();
    var references = try parse(.references, "[{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "}]", "");
    defer references.deinit();
    try t.expectEqual(@as(usize, 1), references.value.len);
    try expectParseError(.definitions, error.InvalidRange, "[{\"targetUri\":\"file:///x\",\"targetRange\":" ++ r01 ++ ",\"targetSelectionRange\":" ++ r02 ++ "}]", "");
    try expectParseError(.references, error.InvalidShape, "{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "}", "");
}

test "hierarchical flat and unresolved workspace symbols" {
    var symbols = try parse(.document_symbols, "[{\"name\":\"outer\",\"kind\":5,\"range\":" ++ r02 ++ ",\"selectionRange\":" ++ r01 ++ ",\"children\":[{\"name\":\"inner\",\"kind\":6,\"range\":" ++ r01 ++ ",\"selectionRange\":" ++ r01 ++ ",\"tags\":[1]}]}]", "ab");
    defer symbols.deinit();
    try t.expect(symbols.value[0].children[0].deprecated);
    var flat = try parse(.document_symbols, "[{\"name\":\"flat\",\"kind\":1,\"location\":{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "}}]", "");
    defer flat.deinit();
    var workspace = try parse(.workspace_symbols, "[{\"name\":\"lazy\",\"kind\":12,\"location\":{\"uri\":\"file:///x\"},\"data\":[1]}]", "");
    defer workspace.deinit();
    try t.expectEqualStrings("file:///x", workspace.value[0].unresolved_uri.?);
    try expectParseError(.document_symbols, error.InvalidRange, "[{\"name\":\"bad\",\"kind\":5,\"range\":" ++ r01 ++ ",\"selectionRange\":" ++ r02 ++ "}]", "ab");
}

test "diagnostics severity version tags related info and code" {
    var result = try parse(.diagnostics, "{\"uri\":\"file:///x\",\"version\":7,\"diagnostics\":[{\"range\":" ++ r02 ++ ",\"severity\":2,\"message\":\"<bad>\",\"source\":\"server\",\"code\":\"E1\",\"codeDescription\":{\"href\":\"https://example.test\"},\"tags\":[1,2],\"relatedInformation\":[{\"location\":{\"uri\":\"file:///y\",\"range\":" ++ r01 ++ "},\"message\":\"related\"}],\"data\":true}]}", "😀");
    defer result.deinit();
    try t.expectEqual(@as(?i32, 7), result.value.version);
    try t.expectEqual(f.Severity.warning, result.value.items[0].severity);
    try t.expect(result.value.items[0].unnecessary and result.value.items[0].deprecated);
    try t.expectEqual(@as(usize, 4), result.value.items[0].range.end);
    try expectParseError(.diagnostics, error.InvalidShape, "{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":" ++ r01 ++ ",\"message\":\"x\",\"severity\":5}]}", "x");
    try expectParseError(.diagnostics, error.OutOfRange, "{\"uri\":\"file:///x\",\"version\":2147483648,\"diagnostics\":[]}", "");
}

test "inlay labelparts commands lenses and unresolved document links" {
    var hints = try parse(.inlay_hints, "[{\"position\":{\"line\":0,\"character\":2},\"label\":[{\"value\":\"T\",\"tooltip\":{\"kind\":\"plaintext\",\"value\":\"type\"},\"location\":{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "},\"command\":{\"title\":\"go\",\"command\":\"jump\"}}],\"kind\":1,\"paddingLeft\":true,\"textEdits\":[" ++ edit02 ++ "]},{\"position\":{\"line\":0,\"character\":0},\"label\":\"plain\"}]", "😀");
    defer hints.deinit();
    try t.expectEqual(@as(usize, 4), hints.value[0].position);
    try t.expectEqualStrings("jump", hints.value[0].label[0].command.?.command);
    var lenses = try parse(.code_lenses, "[{\"range\":" ++ r02 ++ ",\"command\":{\"title\":\"run\",\"command\":\"never.executed\",\"arguments\":[1]},\"data\":1},{\"range\":" ++ r02 ++ "}]", "😀");
    defer lenses.deinit();
    try t.expect(lenses.value[1].command == null);
    var links = try parse(.document_links, "[{\"range\":" ++ r02 ++ ",\"target\":\"javascript:alert(1)\",\"tooltip\":\"<b>literal</b>\"},{\"range\":" ++ r02 ++ ",\"data\":42}]", "😀");
    defer links.deinit();
    // Retaining a target is NOT permission to open it; scheme policy is external.
    try t.expectEqualStrings("javascript:alert(1)", links.value[0].target.?);
    try t.expect(links.value[1].target == null);
    try expectParseError(.inlay_hints, error.InvalidShape, "[{\"position\":{\"line\":0,\"character\":0},\"label\":[]}]", "");
}

const legend: f.Legend = .{ .token_types = &.{ "type", "variable" }, .token_modifiers = &.{ "declaration", "readonly" } };
fn tokens(bytes: []const u8, text: []const u8, prior: ?f.SemanticTokens) !f.Owned(f.SemanticTokens) {
    var p = try json(bytes);
    defer p.deinit();
    return f.parseSemanticTokens(a, p.value, text, .utf16, legend, prior);
}
test "semantic full and delta use integer offsets into original base and own storage" {
    var full = try tokens("{\"resultId\":\"base\",\"data\":[0,0,2,0,1,0,2,1,1,2,1,0,1,0,0]}", "😀a\nb", null);
    defer full.deinit();
    try t.expectEqual(@as(usize, 4), full.value.tokens[0].range.end);
    try t.expectEqual(@as(usize, 6), full.value.tokens[2].range.start);
    // Partial-tuple edit is valid; unsorted, disjoint edits use the old array.
    var delta = try tokens("{\"resultId\":\"next\",\"edits\":[{\"start\":9,\"deleteCount\":1,\"data\":[0]},{\"start\":3,\"deleteCount\":1,\"data\":[1]}]}", "😀a\nb", full.value);
    defer delta.deinit();
    try t.expectEqual(@as(u32, 1), delta.value.tokens[0].token_type);
    try t.expectEqual(@as(u32, 0), delta.value.tokens[1].modifiers);
    try t.expectEqual(@as(u32, 0), full.value.tokens[0].token_type);
    var clear = try tokens("{\"edits\":[{\"start\":0,\"deleteCount\":15}]}", "", full.value);
    defer clear.deinit();
    try t.expectEqual(@as(usize, 0), clear.value.tokens.len);
}
test "semantic bounds legend overlap schema and missing delta base" {
    const cases = [_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = "{\"data\":[0,0,1,0,0]}", .err = error.InvalidBoundary },
        .{ .bytes = "{\"data\":[0,0,2,2,0]}", .err = error.InvalidTokenData },
        .{ .bytes = "{\"data\":[0,0,2,0,4]}", .err = error.InvalidTokenData },
        .{ .bytes = "{\"data\":[0,0,0,0,0]}", .err = error.InvalidTokenData },
        .{ .bytes = "{\"data\":[0,0,2,0]}", .err = error.InvalidTokenData },
        .{ .bytes = "{\"data\":[0,0,3,0,0]}", .err = error.OutOfRange },
        .{ .bytes = "{\"data\":[1,0,1,0,0]}", .err = error.OutOfRange },
        .{ .bytes = "{\"data\":[0,0,2,0,0,0,0,2,0,0]}", .err = error.OverlappingRanges },
        .{ .bytes = "{\"data\":[2147483648,0,2,0,0]}", .err = error.OutOfRange },
        .{ .bytes = "{\"data\":[0.0,0,2,0,0]}", .err = error.InvalidShape },
        .{ .bytes = "{\"edits\":[]}", .err = error.MissingTokenBase },
        .{ .bytes = "{\"data\":[],\"edits\":[]}", .err = error.InvalidShape },
    };
    for (cases) |c| try t.expectError(c.err, tokens(c.bytes, "😀", null));
    var full = try tokens("{\"resultId\":\"b\",\"data\":[0,0,2,0,0]}", "😀", null);
    defer full.deinit();
    try t.expectError(error.OutOfRange, tokens("{\"edits\":[{\"start\":5,\"deleteCount\":1}]}", "😀", full.value));
    try t.expectError(error.OverlappingRanges, tokens("{\"edits\":[{\"start\":0,\"deleteCount\":1},{\"start\":0,\"deleteCount\":0}]}", "😀", full.value));
    try t.expectError(error.InvalidTokenData, tokens("{\"edits\":[{\"start\":0,\"deleteCount\":1}]}", "😀", full.value));
}

test "multi-document Unicode plan retains identities revisions sorted replacements and ownership" {
    var fixture: Fixture = .{};
    var result = try plan(multi_edit, &fixture);
    defer result.deinit();
    try t.expectEqual(e.State.ready, result.state);
    try t.expectEqual(@as(usize, 2), result.targets.len);
    try t.expectEqual(@as(u64, 41), result.targets[0].snapshot.?.revision);
    try t.expectEqual(@as(u64, 15), result.targets[1].snapshot.?.revision);
    try t.expectEqual(@as(usize, 4), result.targets[0].replacements[0].end);
    try t.expectEqual(@as(usize, 4), result.targets[0].replacements[1].start);
    try t.expectEqual(@as(usize, 2), result.targets[1].replacements[0].end);
    try t.expectEqualStrings("😀a\r\nb", result.targets[0].snapshot.?.text);
    try result.validateForApply(fixture.resolver(), &.{});
    fixture.revision += 1;
    try t.expectError(error.StaleRevision, result.validateForApply(fixture.resolver(), &.{}));
    try t.expectError(error.StaleRevision, plan(multi_edit, &fixture));
    fixture.revision = 41;
    fixture.version = 8;
    try t.expectError(error.VersionMismatch, plan(multi_edit, &fixture));
    try t.expectError(error.VersionMismatch, result.validateForApply(fixture.resolver(), &.{}));
    fixture.version = 7;
    fixture.id = 2;
    try t.expectError(error.TargetMismatch, plan(multi_edit, &fixture));
    try t.expectError(error.TargetMismatch, result.validateForApply(fixture.resolver(), &.{}));
    fixture.id = 1;
    fixture.text = "different";
    try t.expectError(error.SnapshotMismatch, result.validateForApply(fixture.resolver(), &.{}));
}

test "overlaps ambiguity versions invalid Unicode and late-document failures reject whole plan" {
    var fixture: Fixture = .{};
    try t.expectError(error.OverlappingRanges, plan("{\"changes\":{\"file:///root/a\":[" ++ edit02 ++ "," ++ edit02 ++ "]}}", &fixture));
    try t.expectError(error.AmbiguousInsertion, plan("{\"changes\":{\"file:///root/a\":[" ++ edit23 ++ ",{\"range\":" ++ r22 ++ ",\"newText\":\"x\"}]}}", &fixture));
    try t.expectError(error.InvalidBoundary, plan("{\"changes\":{\"file:///root/a\":[" ++ edit01 ++ "]}}", &fixture));
    try t.expectError(error.DuplicateDocumentChange, plan("{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":null},\"edits\":[]},{\"textDocument\":{\"uri\":\"file://localhost/root/./a\",\"version\":null},\"edits\":[]}]}", &fixture));
    fixture.version = null;
    try t.expectError(error.VersionMismatch, plan(multi_edit, &fixture));
    fixture.version = 7;
    fixture.text = "\xff";
    try t.expectError(error.InvalidUtf8, plan(multi_edit, &fixture));
    fixture.text = "\x00";
    try t.expectError(error.EmbeddedNul, plan(multi_edit, &fixture));
    fixture.text = "😀a";
    const late = "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":7},\"edits\":[" ++ edit02 ++ "]},{\"textDocument\":{\"uri\":\"file:///root/b\",\"version\":99},\"edits\":[]}]}";
    try t.expectError(error.VersionMismatch, plan(late, &fixture));
    try t.expectEqualStrings("😀a", fixture.text);
}

test "unknown URIs and outside-root snapshots require explicit state and rebuilding" {
    var fixture: Fixture = .{ .auth = .outside_root };
    var outside = try plan(multi_edit, &fixture);
    defer outside.deinit();
    try t.expectEqual(e.State.blocked, outside.state);
    try t.expectEqual(e.Authorization.outside_root, outside.targets[0].authorization);
    try t.expectError(error.AuthorizationRequired, outside.validateForApply(fixture.resolver(), &.{}));
    fixture.auth = .authorized;
    try t.expectError(error.AuthorizationRequired, outside.validateForApply(fixture.resolver(), &.{}));
    fixture.missing = true;
    var unknown = try plan(multi_edit, &fixture);
    defer unknown.deinit();
    try t.expectEqual(e.Authorization.unknown_uri, unknown.targets[0].authorization);
    try t.expect(unknown.targets[0].snapshot == null);
    try t.expectError(error.UnknownUri, unknown.validateForApply(fixture.resolver(), &.{}));
    fixture.missing = false;
    var ready = try plan(multi_edit, &fixture);
    defer ready.deinit();
    fixture.auth = .denied;
    try t.expectError(error.AuthorizationRequired, ready.validateForApply(fixture.resolver(), &.{}));
}

const annotated = "{\"changeAnnotations\":{\"review\":{\"label\":\"Rename\",\"description\":\"Review me\",\"needsConfirmation\":true}},\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":7},\"edits\":[{\"range\":" ++ r02 ++ ",\"newText\":\"ok\",\"annotationId\":\"review\"}]}]}";
test "annotations preserved referenced and explicitly confirmed" {
    var fixture: Fixture = .{};
    var result = try plan(annotated, &fixture);
    defer result.deinit();
    try t.expect(result.needs_confirmation);
    try t.expectEqual(e.State.needs_confirmation, result.state);
    try t.expectEqualStrings("review", result.targets[0].edits[0].annotation_id.?);
    try t.expectEqualStrings("Review me", result.workspace.annotation("review").?.description.?);
    try t.expectError(error.ConfirmationRequired, result.validateForApply(fixture.resolver(), &.{"other"}));
    try result.validateForApply(fixture.resolver(), &.{"review"});
    try t.expectError(error.UnknownAnnotation, plan("{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":null},\"edits\":[{\"range\":" ++ r02 ++ ",\"newText\":\"x\",\"annotationId\":\"missing\"}]}]}", &fixture));
}

const resource_edit = "{\"changeAnnotations\":{\"r\":{\"label\":\"Resources\",\"needsConfirmation\":false}},\"documentChanges\":[{\"kind\":\"create\",\"uri\":\"file:///root/new\",\"options\":{\"overwrite\":true,\"ignoreIfExists\":true},\"annotationId\":\"r\"},{\"textDocument\":{\"uri\":\"file:///root/a\",\"version\":7},\"edits\":[" ++ edit02 ++ "]},{\"kind\":\"rename\",\"oldUri\":\"file:///root/a\",\"newUri\":\"file:///root/new\",\"options\":{\"ignoreIfExists\":true},\"annotationId\":\"r\"},{\"kind\":\"delete\",\"uri\":\"file:///root/b\",\"options\":{\"recursive\":true,\"ignoreIfNotExists\":true}}]}";
test "resources are typed ordered review-only and never permit independent text apply" {
    var fixture: Fixture = .{};
    var result = try plan(resource_edit, &fixture);
    defer result.deinit();
    try t.expectEqual(e.State.resource_review, result.state);
    try t.expect(result.needs_confirmation);
    try t.expectEqual(@as(usize, 3), result.resources.len);
    try t.expectEqual(@as(usize, 2), result.resources[1].operation_index);
    try t.expect(result.resources[0].operation.create.options.overwrite);
    try t.expect(result.resources[0].operation.create.options.ignore_if_exists);
    try t.expectEqualStrings("r", result.resources[1].operation.rename.annotation_id.?);
    try t.expect(result.resources[2].operation.delete.options.recursive);
    try t.expectEqual(e.Authorization.unknown_uri, result.resources[0].source_authorization);
    try t.expectEqual(@as(?e.Authorization, .unknown_uri), result.resources[1].destination_authorization);
    try t.expectError(error.ResourceReviewRequired, result.validateForApply(fixture.resolver(), &.{"r"}));
}

test "WorkspaceEdit schema failures and no-op rename" {
    var fixture: Fixture = .{};
    var noop = try plan("null", &fixture);
    defer noop.deinit();
    try noop.validateForApply(fixture.resolver(), &.{});
    const cases = [_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = "[]", .err = error.InvalidShape },
        .{ .bytes = "{\"changes\":{},\"documentChanges\":[]}", .err = error.AmbiguousWorkspaceEdit },
        .{ .bytes = "{\"changes\":[]}", .err = error.InvalidShape },
        .{ .bytes = "{\"documentChanges\":[{\"kind\":\"copy\",\"uri\":\"file:///x\"}]}", .err = error.UnsupportedResourceOperation },
        .{ .bytes = "{\"documentChanges\":[{\"kind\":\"create\",\"uri\":\"file:///x\",\"options\":{\"overwrite\":1}}]}", .err = error.InvalidShape },
        .{ .bytes = "{\"documentChanges\":[{\"kind\":\"delete\",\"uri\":\"file:///x\",\"annotationId\":\"no\"}]}", .err = error.UnknownAnnotation },
        .{ .bytes = "{\"documentChanges\":[{\"kind\":\"rename\",\"oldUri\":\"file:///x\",\"newUri\":\"file:///x\"}]}", .err = error.InvalidResourceOperation },
        .{ .bytes = "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///x\"},\"edits\":[]}]}", .err = error.MissingField },
        .{ .bytes = "{\"changes\":{\"file:///root/a\":[{\"insert\":" ++ r02 ++ ",\"replace\":" ++ r02 ++ ",\"newText\":\"x\"}]}}", .err = error.InvalidShape },
        .{ .bytes = "{\"changes\":{\"file:///root/a\":[{\"range\":" ++ r02 ++ ",\"newText\":\"\\u0000\"}]}}", .err = error.EmbeddedNul },
        .{ .bytes = "{\"changes\":{\"https://example.test/a\":[]}}", .err = error.InvalidScheme },
    };
    for (cases) |c| try t.expectError(c.err, plan(c.bytes, &fixture));
}

test "position and JSON shape checks never coerce clamp or overflow" {
    try expectParseError(.definitions, error.InvalidUri, "{\"uri\":\"relative/path\",\"range\":" ++ r01 ++ "}", "");
    try expectParseError(.document_links, error.InvalidUri, "[{\"range\":" ++ r01 ++ ",\"target\":\"https://has space\"}]", "a");
    try expectParseError(.diagnostics, error.OutOfRange, "{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":" ++ r01 ++ ",\"message\":\"x\",\"code\":2147483648}]}", "a");
    try expectParseError(.text_edits, error.InvalidShape, "[{\"range\":{\"start\":{\"line\":0.0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"x\"}]", "");
    try expectParseError(.text_edits, error.OutOfRange, "[{\"range\":{\"start\":{\"line\":-1,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"x\"}]", "");
    try expectParseError(.text_edits, error.ReversedRange, "[{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":1}},\"newText\":\"x\"}]", "abc");
    try expectParseError(.text_edits, error.OutOfRange, "[" ++ edit02 ++ "]", "a\r\n");
    try expectParseError(.completion, error.EmbeddedNul, "[{\"label\":\"a\\u0000b\"}]", "");
    try expectParseError(.hover, error.InvalidShape, "{\"contents\":42}", "");
    try expectParseError(.document_links, error.InvalidShape, "[{\"range\":" ++ r01 ++ ",\"target\":false}]", "a");
}

test "list limits and DOM depth bounds" {
    var items = try a.alloc(f.Value, f.max_large_items + 1);
    defer a.free(items);
    @memset(items, .null);
    try t.expectError(error.LimitExceeded, f.parse(.references, a, .{ .array = .{ .items = items, .capacity = items.len, .allocator = a, .pointer_stability = .{} } }, "", .utf16));
    try t.expectError(error.LimitExceeded, f.parse(.completion, a, .{ .array = .{ .items = items[0..513], .capacity = 513, .allocator = a, .pointer_stability = .{} } }, "", .utf16));
    var nodes: [66]f.Value = undefined;
    nodes[65] = .null;
    var i: usize = 65;
    while (i > 0) {
        i -= 1;
        nodes[i] = .{ .array = .{ .items = nodes[i + 1 .. i + 2], .capacity = 1, .allocator = a, .pointer_stability = .{} } };
    }
    try t.expectError(error.LimitExceeded, f.validateJson(nodes[0]));
    try t.expectError(error.InvalidUtf8, f.validateJson(.{ .string = "\xff" }));
}

test "replacement shape agrees with grouped transaction ambiguity policy" {
    var allowed = [_]e.Replacement{ .{ .start = 1, .end = 1, .text = "!" }, .{ .start = 0, .end = 1, .text = "z" } };
    try e.validateReplacements("ab", &allowed);
    try t.expectEqual(@as(usize, 0), allowed[0].start);
    var ambiguous = [_]e.Replacement{ .{ .start = 0, .end = 0, .text = "a" }, .{ .start = 0, .end = 0, .text = "b" } };
    try t.expectError(error.AmbiguousInsertion, e.validateReplacements("", &ambiguous));
    var bad = [_]e.Replacement{.{ .start = 1, .end = 2, .text = "" }};
    try t.expectError(error.InvalidBoundary, e.validateReplacements("😀", &bad));
}

fn allocationScenario(allocator: std.mem.Allocator, completion: f.Value, workspace: f.Value, semantic: f.Value) !void {
    var result = try f.parse(.completion, allocator, completion, "😀a", .utf16);
    defer result.deinit();
    var fixture: Fixture = .{};
    var planned = try e.build(allocator, workspace, fixture.resolver(), .utf16);
    defer planned.deinit();
    var raw = try e.parse(allocator, workspace);
    defer raw.deinit();
    var decoded = try f.parseSemanticTokens(allocator, semantic, "😀a", .utf16, legend, null);
    defer decoded.deinit();
}
test "all allocation failures clean up nested features workspace and semantic models" {
    var completion = try json("[{\"label\":\"f\",\"insertTextFormat\":2,\"insertText\":\"${1:ok}$0\",\"data\":{\"key\":[1,2]},\"command\":{\"title\":\"go\",\"command\":\"go\",\"arguments\":[{\"x\":1}]}}]");
    defer completion.deinit();
    var workspace = try json(resource_edit);
    defer workspace.deinit();
    var semantic = try json("{\"resultId\":\"id\",\"data\":[0,0,2,0,1]}");
    defer semantic.deinit();
    try t.checkAllAllocationFailures(a, allocationScenario, .{ completion.value, workspace.value, semantic.value });
}

test "completion metadata defaults are owned and validated even for empty lists" {
    var result = try parse(.completion, "{\"isIncomplete\":false,\"itemDefaults\":{\"commitCharacters\":[\".\",\"é\"],\"data\":{\"shared\":true}},\"items\":[{\"label\":\"x\",\"labelDetails\":{\"detail\":\"()\",\"description\":\"module\"},\"tags\":[1]},{\"label\":\"y\",\"commitCharacters\":[]}]}", "");
    defer result.deinit();
    try t.expect(result.value.items[0].deprecated);
    try t.expectEqualStrings("module", result.value.items[0].label_details.?.description.?);
    try t.expectEqualStrings("é", result.value.items[0].commit_characters[1]);
    try t.expectEqual(@as(usize, 0), result.value.items[1].commit_characters.len);
    try t.expect(result.value.items[1].data.?.object.get("shared").?.bool);
    try expectParseError(.completion, error.InvalidShape, "{\"isIncomplete\":false,\"itemDefaults\":{\"insertTextFormat\":9},\"items\":[]}", "");
    try expectParseError(.completion, error.MissingField, "{\"isIncomplete\":false,\"itemDefaults\":{\"editRange\":{\"replace\":" ++ r02 ++ "}},\"items\":[]}", "😀");
    try expectParseError(.completion, error.InvalidShape, "[{\"label\":\"x\",\"commitCharacters\":[\"ab\"]}]", "");
}

test "all document encodings, CRLF, combining marks, and signature sanitization" {
    const text = "😀é\r\nx";
    inline for (.{ .{ f.Encoding.utf8, 4, 7 }, .{ f.Encoding.utf16, 2, 4 }, .{ f.Encoding.utf32, 1, 3 } }) |case| {
        const bytes = try std.fmt.allocPrint(a, "[{{\"range\":{{\"start\":{{\"line\":0,\"character\":{d}}},\"end\":{{\"line\":0,\"character\":{d}}}}},\"newText\":\"é\"}}]", .{ case[1], case[2] });
        defer a.free(bytes);
        var dom = try json(bytes);
        defer dom.deinit();
        var result = try f.parse(.text_edits, a, dom.value, text, case[0]);
        defer result.deinit();
        const replacement = try result.value[0].replacement(text, case[0], .replace);
        try t.expectEqual(@as(usize, 4), replacement.start);
        try t.expectEqual(@as(usize, 7), replacement.end);
    }
    var signature = try parse(.signatures, "{\"signatures\":[{\"label\":\"\\u001bf(😀)\",\"parameters\":[{\"label\":[3,5]}]}]}", "");
    defer signature.deinit();
    try t.expectEqualStrings("f(😀)", signature.value.?.signatures[0].label);
    const parameter = signature.value.?.signatures[0].parameters[0];
    try t.expectEqualStrings("😀", signature.value.?.signatures[0].raw_label[parameter.label_range.?.start..parameter.label_range.?.end]);
    var hover = try parse(.hover, "{\"contents\":\"**legacy markdown**\"}", "");
    defer hover.deinit();
    try t.expect(hover.value.?.contents[0].kind == .markdown);
}

test "signature substring expansion has an aggregate output budget" {
    const label = try a.alloc(u8, 64 * 1024);
    defer a.free(label);
    @memset(label, 'x');
    const Param = struct { label: [2]u32 = .{ 0, 64 * 1024 } };
    const params: [512]Param = @splat(.{});
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .signatures = .{.{ .label = label, .parameters = params }} }, .{});
    defer a.free(bytes);
    try expectParseError(.signatures, error.LimitExceeded, bytes, "");
}

fn parserAllocationScenario(comptime kind: f.Kind) type {
    return struct {
        fn run(allocator: std.mem.Allocator, value: f.Value) !void {
            var result = try f.parse(kind, allocator, value, "abc", .utf16);
            defer result.deinit();
        }
    };
}
test "allocation failure cleanup across every remaining parser" {
    const cases = .{
        .{ f.Kind.hover, "{\"contents\":[{\"kind\":\"markdown\",\"value\":\"doc\"}],\"range\":" ++ r01 ++ "}" },
        .{ f.Kind.signatures, "{\"signatures\":[{\"label\":\"abc\",\"documentation\":\"doc\",\"parameters\":[{\"label\":[0,2],\"documentation\":\"param\"}]}]}" },
        .{ f.Kind.definitions, "[{\"targetUri\":\"file:///x\",\"targetRange\":" ++ r02 ++ ",\"targetSelectionRange\":" ++ r01 ++ "}]" },
        .{ f.Kind.references, "[{\"uri\":\"file:///x\",\"range\":" ++ r01 ++ "}]" },
        .{ f.Kind.document_symbols, "[{\"name\":\"outer\",\"kind\":5,\"range\":" ++ r02 ++ ",\"selectionRange\":" ++ r01 ++ ",\"children\":[{\"name\":\"inner\",\"kind\":6,\"range\":" ++ r01 ++ ",\"selectionRange\":" ++ r01 ++ "}]}]" },
        .{ f.Kind.workspace_symbols, "[{\"name\":\"lazy\",\"kind\":12,\"location\":{\"uri\":\"file:///x\"},\"data\":[1]}]" },
        .{ f.Kind.diagnostics, "{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":" ++ r01 ++ ",\"message\":\"error\",\"code\":\"E1\",\"relatedInformation\":[{\"location\":{\"uri\":\"file:///y\",\"range\":" ++ r01 ++ "},\"message\":\"related\"}]}]}" },
        .{ f.Kind.text_edits, "[" ++ edit01 ++ "]" },
        .{ f.Kind.inlay_hints, "[{\"position\":{\"line\":0,\"character\":1},\"label\":[{\"value\":\"T\",\"tooltip\":\"doc\",\"command\":{\"title\":\"go\",\"command\":\"go\",\"arguments\":[{\"n\":1}]}}],\"textEdits\":[" ++ edit01 ++ "],\"data\":[1]}]" },
        .{ f.Kind.code_lenses, "[{\"range\":" ++ r01 ++ ",\"command\":{\"title\":\"go\",\"command\":\"go\",\"arguments\":[1]}}]" },
        .{ f.Kind.document_links, "[{\"range\":" ++ r01 ++ ",\"target\":\"https://example.test\",\"tooltip\":\"doc\",\"data\":[1]}]" },
    };
    inline for (cases) |case| {
        var dom = try json(case[1]);
        defer dom.deinit();
        try t.checkAllAllocationFailures(a, parserAllocationScenario(case[0]).run, .{dom.value});
    }
}

fn deltaAllocationScenario(allocator: std.mem.Allocator, value: f.Value, prior: f.SemanticTokens) !void {
    var result = try f.parseSemanticTokens(allocator, value, "😀a", .utf16, legend, prior);
    defer result.deinit();
}
test "all response kinds reject or safely handle scalar and empty shapes" {
    inline for (comptime std.meta.tags(f.Kind)) |kind| {
        for ([_][]const u8{ "null", "true", "42", "1.25", "\"text\"", "{}", "[]" }) |input| {
            if (parse(kind, input, "")) |owned| {
                var result = owned;
                result.deinit();
            } else |err| {
                // Shape errors are expected, but allocation failures are not.
                try t.expect(err != error.OutOfMemory);
            }
        }
    }
}

test "delta and snippet allocation failure cleanup" {
    var full = try tokens("{\"resultId\":\"id\",\"data\":[0,0,2,0,1]}", "😀a", null);
    defer full.deinit();
    var dom = try json("{\"resultId\":\"next\",\"edits\":[{\"start\":5,\"deleteCount\":0,\"data\":[0,2,1,1,0]}]}");
    defer dom.deinit();
    try t.checkAllAllocationFailures(a, deltaAllocationScenario, .{ dom.value, full.value });
    try t.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const expanded = try f.expandSnippet(allocator, "${1:some long enough default to allocate} ${2|a,b|}");
            defer allocator.free(expanded);
            const escaped = try f.escapeMarkup(allocator, "<script> & <b>literal</b>");
            defer allocator.free(escaped);
        }
    }.run, .{});
}
