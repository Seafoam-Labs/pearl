const std = @import("std");
pub const Kind = enum { selection, background, location, place, bookmark, device, tab };
pub const Facts = struct {
    kind: Kind = .selection,
    count: usize = 0,
    all_directories: bool = false,
    can_write: bool = false,
    can_rename: bool = false,
    can_delete: bool = false,
    can_trash: bool = false,
    clipboard: bool = false,
    trash: bool = false,
    busy: bool = false,
    local: bool = false,
};
pub const Capability = enum { open, rename, copy, cut, paste, create, trash, delete, restore, terminal, properties };
pub fn enabled(f: Facts, c: Capability) bool {
    return switch (c) {
        .open, .copy => f.count > 0 and !f.trash,
        .rename => f.count == 1 and f.can_rename and !f.trash and !f.busy,
        .cut => f.count > 0 and f.can_delete and !f.trash,
        .paste => f.clipboard and f.can_write and !f.trash and !f.busy,
        .create => f.can_write and !f.trash and !f.busy,
        .trash => f.count > 0 and f.can_trash and !f.trash and !f.busy,
        .delete => f.count > 0 and f.can_delete and !f.busy,
        .restore => f.count > 0 and f.trash and !f.busy,
        .terminal => f.local and (f.count == 0 or (f.count == 1 and f.all_directories)) and !f.trash,
        .properties => true,
    };
}
test "mixed selections and virtual locations cannot inherit single-file mutation capabilities" {
    const t = std.testing;
    var f: Facts = .{ .count = 3, .can_delete = true, .can_trash = true, .can_rename = true, .local = true };
    try t.expect(!enabled(f, .rename));
    try t.expect(enabled(f, .trash));
    try t.expect(!enabled(f, .terminal));
    f.trash = true;
    try t.expect(!enabled(f, .copy));
    try t.expect(!enabled(f, .trash));
    try t.expect(enabled(f, .restore));
    f.busy = true;
    try t.expect(!enabled(f, .restore));
}
test "paste requires both supported clipboard and destination capability" {
    const t = std.testing;
    var f: Facts = .{ .kind = .background, .clipboard = true };
    try t.expect(!enabled(f, .paste));
    f.can_write = true;
    try t.expect(enabled(f, .paste));
    f.trash = true;
    try t.expect(!enabled(f, .paste));
}
