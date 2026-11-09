//! Bounded version-1 .coral-workspace JSON. No filesystem access or execution.
//! Only empty settings are supported in this first M2 slice: no key is ignored.
//! All returned strings are owned; callers may release the input after parse().
const std = @import("std");

pub const limits = struct {
    pub const manifest_bytes = 1024 * 1024;
    pub const roots = 32;
    // Linux native path limit, excluding the terminating NUL.
    pub const path_bytes = 4095;
    pub const name_bytes = 256;
    pub const excludes = 128;
    pub const exclude_bytes = 1024;
};

pub const Root = struct { name: ?[]const u8 = null, path: []const u8 };

/// Move-only owner. Fields are immutable views valid until deinit().
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    roots: []const Root,
    /// Final, root-relative hide patterns, applied independently to each root.
    exclude: []const []const u8 = &.{},

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    TooLarge,
    EmptyString,
    EmbeddedNul,
    InvalidUtf8,
    InvalidSchema,
    DuplicateField,
    UnknownField,
    UnsupportedVersion,
    UnsupportedSettings,
    OutOfMemory,
};

pub fn validateString(value: []const u8, maximum: usize) Error!void {
    if (value.len > maximum) return error.TooLarge;
    if (value.len == 0) return error.EmptyString;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
}

/// Accepts 0..32 roots, exact integer version 1, optional nonempty names, and
/// optional empty settings object and <=128 root-relative exclude globs (<=1024
/// bytes each; final hides, no negation). Unknown/duplicate fields (including escaped
/// spellings), explicit null optionals, trailing documents and future versions
/// fail closed. Parsing has fixed schema depth, never builds arbitrary JSON trees.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Manifest {
    if (bytes.len > limits.manifest_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    var p = Parser{ .allocator = arena.allocator(), .scanner = .initCompleteInput(allocator, bytes) };
    defer p.scanner.deinit();
    try p.expect(.object_begin);
    var seen: u8 = 0;
    var roots: [limits.roots]Root = undefined;
    var count: usize = 0;
    var excludes: [limits.excludes][]const u8 = undefined;
    var exclude_count: usize = 0;
    while (true) {
        const token = try p.next();
        if (token == .object_end) break;
        const key = try string(token);
        const bit: u8 = if (std.mem.eql(u8, key, "version")) 1 else if (std.mem.eql(u8, key, "roots")) 2 else if (std.mem.eql(u8, key, "settings")) 4 else if (std.mem.eql(u8, key, "exclude")) 8 else return error.UnknownField;
        if (seen & bit != 0) return error.DuplicateField;
        seen |= bit;
        switch (bit) {
            1 => {
                const version = switch (try p.next()) {
                    .number, .allocated_number => |n| n,
                    else => return error.InvalidSchema,
                };
                if (!std.mem.eql(u8, version, "1")) return error.UnsupportedVersion;
            },
            2 => {
                try p.expect(.array_begin);
                while (true) {
                    const start = try p.next();
                    if (start == .array_end) break;
                    if (count == limits.roots) return error.TooLarge;
                    if (start != .object_begin) return error.InvalidSchema;
                    roots[count] = try p.root();
                    count += 1;
                }
            },
            4 => {
                try p.expect(.object_begin);
                if (try p.next() != .object_end) return error.UnsupportedSettings;
            },
            8 => {
                try p.expect(.array_begin);
                while (true) {
                    const item = try p.next();
                    if (item == .array_end) break;
                    if (exclude_count == limits.excludes) return error.TooLarge;
                    const pattern = try string(item);
                    try validateString(pattern, limits.exclude_bytes);
                    try @import("ignore.zig").validateExclude(pattern);
                    excludes[exclude_count] = pattern;
                    exclude_count += 1;
                }
            },
            else => unreachable,
        }
    }
    if (seen & 3 != 3) return error.InvalidSchema;
    try p.expect(.end_of_document);
    return .{ .roots = try arena.allocator().dupe(Root, roots[0..count]), .exclude = try arena.allocator().dupe([]const u8, excludes[0..exclude_count]), .arena = arena };
}

fn string(token: std.json.Token) Error![]const u8 {
    return switch (token) {
        .string, .allocated_string => |s| s,
        else => error.InvalidSchema,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: std.json.Scanner,

    fn next(self: *Parser) Error!std.json.Token {
        return self.scanner.nextAllocMax(self.allocator, .alloc_always, limits.path_bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ValueTooLong => error.TooLarge,
            else => error.InvalidSchema,
        };
    }

    fn expect(self: *Parser, tag: std.meta.Tag(std.json.Token)) Error!void {
        if (std.meta.activeTag(try self.next()) != tag) return error.InvalidSchema;
    }

    fn root(self: *Parser) Error!Root {
        var result: Root = .{ .path = undefined };
        var seen: u8 = 0;
        while (true) {
            const token = try self.next();
            if (token == .object_end) break;
            const key = try string(token);
            const bit: u8 = if (std.mem.eql(u8, key, "path")) 1 else if (std.mem.eql(u8, key, "name")) 2 else return error.UnknownField;
            if (seen & bit != 0) return error.DuplicateField;
            seen |= bit;
            const value = try string(try self.next());
            try validateString(value, if (bit == 1) limits.path_bytes else limits.name_bytes);
            if (bit == 1) result.path = value else result.name = value;
        }
        if (seen & 1 == 0) return error.InvalidSchema;
        return result;
    }
};

test {
    _ = @import("manifest_test.zig");
}
