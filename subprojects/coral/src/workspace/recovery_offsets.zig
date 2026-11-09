//! Pure validation/conversion at the GTK-character / recovery-byte boundary.
const std = @import("std");
const model = @import("recovery_model.zig");

pub fn byteAtChar(text: []const u8, offset: c_int) usize {
    var byte: usize = 0;
    var char: c_int = 0;
    while (byte < text.len and char < offset) : (char += 1) {
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }
    return @min(byte, text.len);
}

pub fn charAtByte(text: []const u8, offset: u64) !c_int {
    if (offset > text.len) return error.InvalidSnapshot;
    if (offset < text.len and text[@intCast(offset)] & 0xc0 == 0x80) return error.InvalidSnapshot;
    return @intCast(try std.unicode.utf8CountCodepoints(text[0..@intCast(offset)]));
}

pub fn validateRestore(snapshot: model.Snapshot) !void {
    try model.validate(snapshot);
    for (snapshot.groups) |group| {
        // The current App only exposes equal-width, horizontal notebook groups.
        if (group.split != .leaf or group.ratio != 5000) return error.UnsupportedLayout;
    }
    for (snapshot.documents) |doc| {
        if (doc.newline == .cr) return error.UnsupportedLineEnding;
        if (!std.unicode.utf8ValidateSlice(doc.text) or std.mem.indexOfScalar(u8, doc.text, 0) != null) return error.InvalidUtf8;
        var found = false;
        for (snapshot.views) |view| if (view.document_id == doc.id) {
            found = true;
            const presented = try model.presentationText(doc.text, view);
            _ = try charAtByte(presented, view.cursor);
            _ = try charAtByte(presented, view.anchor);
            if (view.scroll_line > std.math.maxInt(c_int)) return error.InvalidSnapshot;
        };
        if (!found) return error.UnsupportedLayout;
    }
}

test "directed Unicode selection uses bytes on disk, characters in GTK" {
    const text = "α😀z\nβ";
    try std.testing.expectEqual(@as(usize, 6), byteAtChar(text, 2));
    try std.testing.expectEqual(@as(c_int, 2), try charAtByte(text, 6));
    try std.testing.expectError(error.InvalidSnapshot, charAtByte(text, 3));
    try std.testing.expectEqual(text.len, byteAtChar(text, 999));
    try std.testing.expectEqual(@as(usize, 0), byteAtChar(text, -1));
}

test "restore preflight rejects unsupported and invalid state before UI mutation" {
    var docs = [_]model.Document{.{ .id = 1, .text = "α" }};
    var views = [_]model.View{.{ .id = 1, .document_id = 1, .group_path = "root/0", .cursor = 2 }};
    var groups = [_]model.Group{.{ .path = "root/0", .active_view = 1 }};
    const snapshot: model.Snapshot = .{ .documents = &docs, .groups = &groups, .views = &views };
    try validateRestore(snapshot);
    docs[0].newline = .cr;
    try std.testing.expectError(error.UnsupportedLineEnding, validateRestore(snapshot));
    docs[0].newline = .mixed;
    try validateRestore(snapshot);
    views[0].cursor = 1;
    try std.testing.expectError(error.InvalidSnapshot, validateRestore(snapshot));
    views[0].cursor = 2;
    groups[0].split = .vertical;
    try std.testing.expectError(error.UnsupportedLayout, validateRestore(snapshot));
    try std.testing.expectError(error.UnsupportedLayout, validateRestore(.{ .documents = &docs }));
}
