//! Markdown skills loader: parse, search, and prompt injection.
//!
//! A skill is a markdown file with optional YAML-ish frontmatter delimited by
//! `---` lines carrying `name:` and `description:`. Without frontmatter the
//! filename stem becomes the name. Skills are searched by keyword and the
//! selected ones are rendered into a system-prompt section with disclosure of
//! their source paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
    path: []const u8,

    pub fn deinit(self: *Skill, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.body);
        allocator.free(self.path);
    }
};

pub const Match = struct { index: usize, score: usize };

pub const Skills = struct {
    allocator: Allocator,
    skills: std.ArrayList(Skill) = .empty,

    pub fn init(allocator: Allocator) Skills {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Skills) void {
        for (self.skills.items) |*s| s.deinit(self.allocator);
        self.skills.deinit(self.allocator);
    }

    /// Parse a single skill document. `name_hint` is the filename stem.
    pub fn parse(allocator: Allocator, name_hint: []const u8, text: []const u8, path: []const u8) !Skill {
        var name: ?[]const u8 = null;
        var description: []const u8 = "";
        var body = text;

        if (std.mem.startsWith(u8, text, "---\n") or std.mem.startsWith(u8, text, "---\r\n")) {
            const start: usize = if (text[3] == '\r') 5 else 4;
            if (std.mem.indexOf(u8, text[start..], "\n---")) |close_rel| {
                const front = text[start .. start + close_rel];
                var lines = std.mem.splitScalar(u8, front, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \r");
                    if (std.mem.startsWith(u8, trimmed, "name:")) {
                        name = std.mem.trim(u8, trimmed["name:".len..], " ");
                    } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                        description = std.mem.trim(u8, trimmed["description:".len..], " ");
                    }
                }
                var body_start = start + close_rel + "\n---".len;
                if (body_start < text.len and text[body_start] == '\r') body_start += 1;
                if (body_start < text.len and text[body_start] == '\n') body_start += 1;
                body = text[body_start..];
            }
        }

        return .{
            .name = try allocator.dupe(u8, name orelse name_hint),
            .description = try allocator.dupe(u8, description),
            .body = try allocator.dupe(u8, body),
            .path = try allocator.dupe(u8, path),
        };
    }

    /// Load every `*.md` file in `dir_path`. A missing directory is a no-op.
    pub fn loadDir(self: *Skills, io: Io, dir_path: []const u8) !void {
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const bytes = dir.readFileAlloc(io, entry.name, self.allocator, .limited(1024 * 1024)) catch continue;
            defer self.allocator.free(bytes);
            const stem = entry.name[0 .. entry.name.len - ".md".len];
            const full = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(full);
            const skill = try Skills.parse(self.allocator, stem, bytes, full);
            try self.skills.append(self.allocator, skill);
        }
    }

    /// Rank skills against a query (case-insensitive substring scoring).
    /// Caller owns the returned slice.
    pub fn search(self: *const Skills, allocator: Allocator, query: []const u8) ![]Match {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const q = try lower(a, query);
        var matches: std.ArrayList(Match) = .empty;
        for (self.skills.items, 0..) |skill, i| {
            var score: usize = 0;
            const name = try lower(a, skill.name);
            const desc = try lower(a, skill.description);
            const body = try lower(a, skill.body);
            if (q.len > 0) {
                if (std.mem.indexOf(u8, name, q) != null) score += 10;
                if (std.mem.indexOf(u8, desc, q) != null) score += 5;
                if (std.mem.indexOf(u8, body, q) != null) score += 1;
            }
            if (score > 0) try matches.append(allocator, .{ .index = i, .score = score });
        }
        std.mem.sort(Match, matches.items, {}, struct {
            fn lessThan(_: void, lhs: Match, rhs: Match) bool {
                return lhs.score > rhs.score;
            }
        }.lessThan);
        return matches.toOwnedSlice(allocator);
    }

    /// Render selected skills into a prompt section with source disclosure.
    pub fn renderPrompt(self: *const Skills, allocator: Allocator, indices: []const usize) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.appendSlice(allocator, "## Available skills\n");
        for (indices) |i| {
            if (i >= self.skills.items.len) continue;
            const s = self.skills.items[i];
            try list.print(allocator, "### {s}\n", .{s.name});
            if (s.description.len > 0) try list.print(allocator, "{s}\n", .{s.description});
            try list.print(allocator, "(source: {s})\n", .{s.path});
            try list.appendSlice(allocator, s.body);
            if (s.body.len == 0 or s.body[s.body.len - 1] != '\n') try list.append(allocator, '\n');
            try list.append(allocator, '\n');
        }
        return list.toOwnedSlice(allocator);
    }

    fn lower(allocator: Allocator, text: []const u8) ![]u8 {
        const out = try allocator.dupe(u8, text);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return out;
    }
};

test "parse frontmatter and body" {
    const a = std.testing.allocator;
    const text = "---\nname: zig-style\ndescription: Zig conventions\n---\nUse Zig.\n";
    var skill = try Skills.parse(a, "fallback", text, "/skills/zig.md");
    defer skill.deinit(a);
    try std.testing.expectEqualStrings("zig-style", skill.name);
    try std.testing.expectEqualStrings("Zig conventions", skill.description);
    try std.testing.expectEqualStrings("Use Zig.\n", skill.body);
}

test "parse without frontmatter uses name hint" {
    const a = std.testing.allocator;
    var skill = try Skills.parse(a, "my-skill", "Just body text.", "/s/my-skill.md");
    defer skill.deinit(a);
    try std.testing.expectEqualStrings("my-skill", skill.name);
    try std.testing.expectEqualStrings("", skill.description);
    try std.testing.expectEqualStrings("Just body text.", skill.body);
}

test "search ranks name over body" {
    const a = std.testing.allocator;
    var skills = Skills.init(a);
    defer skills.deinit();
    try skills.skills.append(a, try Skills.parse(a, "a", "---\nname: git\n---\nbody about zig", "/a.md"));
    try skills.skills.append(a, try Skills.parse(a, "b", "---\nname: zig\n---\nbody", "/b.md"));
    const matches = try skills.search(a, "zig");
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 1), matches[0].index); // name match first
}

test "renderPrompt injects selected skills" {
    const a = std.testing.allocator;
    var skills = Skills.init(a);
    defer skills.deinit();
    try skills.skills.append(a, try Skills.parse(a, "a", "---\nname: git\ndescription: Git help\n---\nCommit often.", "/a.md"));
    const prompt = try skills.renderPrompt(a, &.{0});
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "### git") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Commit often.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "/a.md") != null);
}
