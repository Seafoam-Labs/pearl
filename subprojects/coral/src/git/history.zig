//! Pure file-history, commit-diff, blame and host-permalink policy for the M4
//! native Source Control workflows. No process spawning, GTK, filesystem or
//! network access happens here. Argv builders return git subcommand arguments
//! (without a prefix); the controller prepends command.zig's read-only prefix.
//! Permalinks are constructed for GitHub/GitLab/Codeberg only and must pass
//! validateHttpsUrl before the controller offers them to the user's default
//! browser through a separate external-link confirmation. There is no PR API.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_log_entries = 500;
pub const max_blame_lines = 5000;
pub const max_input_bytes = 1024 * 1024;
pub const max_permalink_bytes = 2048;
pub const max_oid_bytes = 64;
pub const min_oid_bytes = 4;
pub const max_path_bytes = 4096;
pub const max_field_bytes = 4096;

// git log field/record separators: US (0x1f) between fields, RS (0x1e) between
// records. Subjects are single-line; fields containing these controls fail closed.
const field_sep = 0x1f;
const record_sep = 0x1e;
pub const log_format = "%H%x1f%an%x1f%ad%x1f%s%x1e";

pub const LogEntry = struct {
    oid: []const u8,
    author: []const u8,
    date: []const u8,
    subject: []const u8,
};

pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    entries: []LogEntry,

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const BlameLine = struct {
    oid: []const u8,
    author: []const u8,
    summary: []const u8,
    line_no: usize,
    text: []const u8,
};

pub const Blame = struct {
    arena: std.heap.ArenaAllocator,
    lines: []BlameLine,

    pub fn deinit(self: *Blame) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Host = enum { github, gitlab, codeberg };

pub const WebRemote = struct {
    host: Host,
    /// Repository owner (GitLab subgroups keep their '/' separators).
    owner: []const u8,
    repo: []const u8,

    /// owner and repo are independent allocations owned by the caller.
    pub fn deinit(self: WebRemote, allocator: Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    InvalidUtf8,
    TooManyEntries,
    TooManyBlameLines,
    InvalidRecord,
    InvalidOid,
    InvalidPath,
    InvalidUrl,
    InvalidLine,
    UnsupportedHost,
    FieldTooLong,
};

pub fn validOid(oid: []const u8) bool {
    if (oid.len < min_oid_bytes or oid.len > max_oid_bytes) return false;
    for (oid) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn controlFree(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch < 32 or ch == 127) return false;
    }
    return true;
}

/// Repository-relative POSIX path: non-empty, bounded, no NUL/control/backslash,
/// no absolute prefix and no '.'/'..' components. Lexical only, not symlink
/// authorization; the controller passes it after '--' to git.
pub fn validRelPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    if (!controlFree(path)) return false;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// `git log --no-color --no-decorate --date=short --format=<fmt> -n <limit> -- <path>`.
pub fn logArgs(allocator: Allocator, path: []const u8, limit: usize) (Allocator.Error || error{InvalidPath})![][]const u8 {
    if (!validRelPath(path)) return error.InvalidPath;
    const count = try std.fmt.allocPrint(allocator, "{d}", .{@min(limit, max_log_entries)});
    errdefer allocator.free(count);
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "log", "--no-color", "--no-decorate", "--date=short", "--format=" ++ log_format, "-n" });
    try args.append(allocator, count);
    try args.append(allocator, "--");
    try args.append(allocator, path);
    return args.toOwnedSlice(allocator);
}

/// `git show --no-color --no-ext-diff --no-textconv --no-renames
/// --ignore-submodules=all --no-notes --format=medium <oid>`.
pub fn commitDiffArgs(allocator: Allocator, oid: []const u8) (Allocator.Error || error{InvalidOid})![][]const u8 {
    if (!validOid(oid)) return error.InvalidOid;
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "show", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "--no-notes", "--format=medium" });
    try args.append(allocator, oid);
    return args.toOwnedSlice(allocator);
}

/// `git blame --porcelain <rev> -- <path>`. Bounded by the controller's capture
/// limit and parseBlame's line budget.
pub fn blameArgs(allocator: Allocator, rev: []const u8, path: []const u8) (Allocator.Error || error{ InvalidPath, InvalidOid })![][]const u8 {
    if (!validRelPath(path)) return error.InvalidPath;
    if (!std.mem.eql(u8, rev, "HEAD") and !validOid(rev)) return error.InvalidOid;
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "blame", "--porcelain" });
    try args.append(allocator, rev);
    try args.append(allocator, "--");
    try args.append(allocator, path);
    return args.toOwnedSlice(allocator);
}

fn fieldOk(bytes: []const u8) bool {
    return bytes.len <= max_field_bytes and controlFree(bytes);
}

/// Parse the log_format record stream. Fails closed on malformed records,
/// oversized fields/input or too many entries.
pub fn parseLog(allocator: Allocator, bytes: []const u8) ParseError!Log {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var result: Log = .{ .arena = std.heap.ArenaAllocator.init(allocator), .entries = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var entries: std.ArrayList(LogEntry) = .empty;
    var records = std.mem.splitScalar(u8, bytes, record_sep);
    while (records.next()) |record| {
        // git log's default tformat terminator places a newline AFTER each record
        // separator, so it prefixes the following record. Tolerate it.
        var rec = record;
        if (rec.len > 0 and rec[0] == '\n') rec = rec[1..];
        if (rec.len == 0) continue;
        // Each record is exactly four fields; a trailing newline before the
        // record separator belongs to the subject and is trimmed.
        var fields: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, rec, field_sep);
        while (it.next()) |f| {
            if (count == 4) return error.InvalidRecord;
            fields[count] = f;
            count += 1;
        }
        if (count != 4) return error.InvalidRecord;
        if (!validOid(fields[0])) return error.InvalidOid;
        var subject = fields[3];
        if (subject.len > 0 and subject[subject.len - 1] == '\n') subject = subject[0 .. subject.len - 1];
        if (!fieldOk(fields[1]) or !fieldOk(fields[2]) or !fieldOk(subject)) return error.FieldTooLong;
        if (entries.items.len >= max_log_entries) return error.TooManyEntries;
        try entries.append(a, .{
            .oid = try a.dupe(u8, fields[0]),
            .author = try a.dupe(u8, fields[1]),
            .date = try a.dupe(u8, fields[2]),
            .subject = try a.dupe(u8, subject),
        });
    }
    result.entries = try entries.toOwnedSlice(a);
    return result;
}

const BlameMeta = struct { author: []const u8 = "", summary: []const u8 = "" };

fn blameHeader(line: []const u8) ?struct { oid: []const u8, final: usize } {
    // <hex-oid> <orig-line> <final-line> [<group-count>]
    var it = std.mem.splitScalar(u8, line, ' ');
    const oid = it.next() orelse return null;
    if (!validOid(oid)) return null;
    _ = it.next() orelse return null; // original line number
    const final_text = it.next() orelse return null;
    const final = std.fmt.parseInt(usize, final_text, 10) catch return null;
    if (final == 0) return null;
    if (it.next()) |group| {
        _ = std.fmt.parseInt(usize, group, 10) catch return null;
        if (it.next() != null) return null;
    }
    return .{ .oid = oid, .final = final };
}

/// Parse `git blame --porcelain`. Handles first-occurrence metadata, repeated
/// commits (metadata omitted) and grouped consecutive lines (a single header
/// followed by several TAB-prefixed content lines). Bounded and fail-closed.
pub fn parseBlame(allocator: Allocator, bytes: []const u8) ParseError!Blame {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    var result: Blame = .{ .arena = std.heap.ArenaAllocator.init(allocator), .lines = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var lines: std.ArrayList(BlameLine) = .empty;
    var meta = std.StringHashMap(BlameMeta).init(a);
    var current_oid: []const u8 = "";
    var current_final: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            if (current_oid.len == 0) return error.InvalidRecord;
            if (lines.items.len >= max_blame_lines) return error.TooManyBlameLines;
            const m = meta.get(current_oid) orelse BlameMeta{};
            try lines.append(a, .{
                .oid = current_oid,
                .author = m.author,
                .summary = m.summary,
                .line_no = current_final,
                .text = try a.dupe(u8, line[1..]),
            });
            current_final += 1;
            continue;
        }
        if (blameHeader(line)) |header| {
            current_oid = try a.dupe(u8, header.oid);
            current_final = header.final;
            continue;
        }
        if (current_oid.len == 0) continue; // leading metadata before any header
        if (std.mem.startsWith(u8, line, "author ")) {
            const value = line["author ".len..];
            if (!fieldOk(value)) return error.FieldTooLong;
            const entry = try meta.getOrPut(current_oid);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.author = try a.dupe(u8, value);
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            const value = line["summary ".len..];
            if (!fieldOk(value)) return error.FieldTooLong;
            const entry = try meta.getOrPut(current_oid);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.summary = try a.dupe(u8, value);
        }
        // Other metadata (author-mail/time/tz, committer*, filename, previous,
        // boundary) is intentionally ignored.
    }
    result.lines = try lines.toOwnedSlice(a);
    return result;
}

fn hostFromName(name: []const u8) ?Host {
    var host = name;
    if (std.mem.startsWith(u8, host, "www.")) host = host[4..];
    if (std.ascii.eqlIgnoreCase(host, "github.com")) return .github;
    if (std.ascii.eqlIgnoreCase(host, "gitlab.com")) return .gitlab;
    if (std.ascii.eqlIgnoreCase(host, "codeberg.org")) return .codeberg;
    return null;
}

fn validRepoComponent(part: []const u8) bool {
    if (part.len == 0 or part.len > max_path_bytes) return false;
    if (!controlFree(part)) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    if (std.mem.indexOfScalar(u8, part, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, part, '/') != null) return false;
    return true;
}

/// Extract host/owner/repo from an https or ssh remote URL. The `.git` suffix is
/// stripped from the repository name. Only GitHub/GitLab/Codeberg are supported;
/// other hosts return UnsupportedHost (no generic permalink guessing, no PR API).
pub fn parseWebRemote(allocator: Allocator, remote_url: []const u8) ParseError!WebRemote {
    if (remote_url.len == 0 or remote_url.len > max_permalink_bytes) return error.InvalidUrl;
    if (!controlFree(remote_url)) return error.InvalidUrl;
    var host_text: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.startsWith(u8, remote_url, "https://")) {
        const rest = remote_url["https://".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUrl;
        host_text = rest[0..slash];
        path = rest[slash + 1 ..];
    } else if (std.mem.startsWith(u8, remote_url, "ssh://")) {
        const rest = remote_url["ssh://".len..];
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidUrl;
        const after = rest[at + 1 ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return error.InvalidUrl;
        host_text = after[0..slash];
        path = after[slash + 1 ..];
    } else if (std.mem.startsWith(u8, remote_url, "git@")) {
        // scp-like: git@host:owner/repo.git
        const rest = remote_url["git@".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidUrl;
        host_text = rest[0..colon];
        path = rest[colon + 1 ..];
    } else {
        return error.InvalidUrl;
    }
    // Strip an optional :port from the host.
    if (std.mem.indexOfScalar(u8, host_text, ':')) |colon| host_text = host_text[0..colon];
    const host = hostFromName(host_text) orelse return error.UnsupportedHost;
    if (path.len == 0) return error.InvalidUrl;
    // Drop query/fragment if a remote URL somehow carries them.
    if (std.mem.indexOfAny(u8, path, "?#")) |end| path = path[0..end];
    var trimmed = path;
    if (std.mem.endsWith(u8, trimmed, ".git")) trimmed = trimmed[0 .. trimmed.len - ".git".len];
    if (trimmed.len == 0) return error.InvalidUrl;
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.InvalidUrl;
    const owner = trimmed[0..last_slash];
    const repo = trimmed[last_slash + 1 ..];
    if (owner.len == 0 or !validRepoComponent(repo)) return error.InvalidUrl;
    var parts = std.mem.splitScalar(u8, owner, '/');
    while (parts.next()) |part| {
        if (!validRepoComponent(part)) return error.InvalidUrl;
    }
    const owned_owner = try allocator.dupe(u8, owner);
    errdefer allocator.free(owned_owner);
    const owned_repo = try allocator.dupe(u8, repo);
    return .{ .host = host, .owner = owned_owner, .repo = owned_repo };
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// Percent-encode a repository-relative path for a URL path, preserving '/'
/// separators. Emits ASCII only.
fn encodePath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (unreserved(ch) or ch == '/') {
            try out.append(allocator, ch);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Strict https URL guard used before any external launch. Requires the https
/// scheme, a non-empty host without userinfo, printable ASCII only (no spaces,
/// controls, backslashes or raw non-ASCII), bounded length and no '..' path
/// segment. This is not a fetch; it only validates a string for the browser.
pub fn validateHttpsUrl(url: []const u8) (error{InvalidUrl} || Allocator.Error)!void {
    if (url.len == 0 or url.len > max_permalink_bytes) return error.InvalidUrl;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    for (url) |ch| {
        if (ch <= 32 or ch >= 127 or ch == '\\') return error.InvalidUrl;
    }
    const rest = url["https://".len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    const host = if (std.mem.indexOfScalar(u8, authority, ':')) |colon| authority[0..colon] else authority;
    if (host.len == 0) return error.InvalidUrl;
    if (host[0] == '.' or host[0] == '-' or host[host.len - 1] == '.' or host[host.len - 1] == '-') return error.InvalidUrl;
    for (host) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') return error.InvalidUrl;
    }
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        const port = authority[colon + 1 ..];
        if (port.len == 0) return error.InvalidUrl;
        for (port) |ch| {
            if (!std.ascii.isDigit(ch)) return error.InvalidUrl;
        }
    }
    // Reject dot-segment traversal anywhere in the path.
    const path_start = authority_end;
    if (path_start < rest.len and rest[path_start] == '/') {
        const path_end = std.mem.indexOfAny(u8, rest[path_start..], "?#") orelse rest.len - path_start;
        const path = rest[path_start .. path_start + path_end];
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return error.InvalidUrl;
        }
    }
}

/// Build a blob permalink for GitHub/GitLab/Codeberg at a commit and 1-based
/// line. The result is owned by the caller and has passed validateHttpsUrl.
pub fn buildPermalink(allocator: Allocator, remote_url: []const u8, oid: []const u8, path: []const u8, line: usize) ParseError![]u8 {
    if (!validOid(oid)) return error.InvalidOid;
    if (!validRelPath(path)) return error.InvalidPath;
    if (line == 0) return error.InvalidLine;
    const web = try parseWebRemote(allocator, remote_url);
    defer web.deinit(allocator);
    const encoded = try encodePath(allocator, path);
    defer allocator.free(encoded);
    const url = switch (web.host) {
        .github => try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/blob/{s}/{s}#L{d}", .{ web.owner, web.repo, oid, encoded, line }),
        .gitlab => try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}/-/blob/{s}/{s}#L{d}", .{ web.owner, web.repo, oid, encoded, line }),
        .codeberg => try std.fmt.allocPrint(allocator, "https://codeberg.org/{s}/{s}/src/commit/{s}/{s}#L{d}", .{ web.owner, web.repo, oid, encoded, line }),
    };
    errdefer allocator.free(url);
    if (url.len > max_permalink_bytes) return error.InvalidUrl;
    try validateHttpsUrl(url);
    return url;
}

test "oid and relative path validation" {
    const t = std.testing;
    try t.expect(validOid("0123456789abcdef0123456789abcdef01234567"));
    try t.expect(validOid("abcd"));
    try t.expect(!validOid("abc"));
    try t.expect(!validOid("zzzz"));
    try t.expect(!validOid(""));
    try t.expect(validRelPath("src/main.zig"));
    try t.expect(validRelPath("a b/c.txt"));
    try t.expect(!validRelPath("/abs"));
    try t.expect(!validRelPath("../escape"));
    try t.expect(!validRelPath("a/../b"));
    try t.expect(!validRelPath("a//b"));
    try t.expect(!validRelPath("a\\b"));
    try t.expect(!validRelPath(""));
}

test "log argv and parser round-trip with bounds" {
    const t = std.testing;
    const args = try logArgs(t.allocator, "src/main.zig", 50);
    defer {
        t.allocator.free(args[6]); // the allocated -n count
        t.allocator.free(args);
    }
    try t.expectEqualStrings("log", args[0]);
    try t.expectEqualStrings("--", args[args.len - 2]);
    try t.expectEqualStrings("src/main.zig", args[args.len - 1]);
    try t.expectError(error.InvalidPath, logArgs(t.allocator, "../x", 10));

    const oid = "0123456789abcdef0123456789abcdef01234567";
    const sample = oid ++ "\x1fAda\x1f2026-01-02\x1fInitial commit\x1e" ++ oid ++ "\x1fGrace\x1f2026-01-03\x1fFix thing\x1e";
    var log = try parseLog(t.allocator, sample);
    defer log.deinit();
    try t.expectEqual(@as(usize, 2), log.entries.len);
    try t.expectEqualStrings(oid, log.entries[0].oid);
    try t.expectEqualStrings("Ada", log.entries[0].author);
    try t.expectEqualStrings("2026-01-02", log.entries[0].date);
    try t.expectEqualStrings("Initial commit", log.entries[0].subject);
    try t.expectEqualStrings("Fix thing", log.entries[1].subject);

    try t.expectError(error.InvalidOid, parseLog(t.allocator, "nothex\x1fA\x1f2026\x1fs\x1e"));
    try t.expectError(error.InvalidRecord, parseLog(t.allocator, oid ++ "\x1fA\x1f2026\x1e"));
}

test "blame porcelain parses groups, repeated commits and metadata" {
    const t = std.testing;
    const oid_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oid_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const sample =
        oid_a ++ " 1 1 2\n" ++
        "author Ada\n" ++
        "author-mail <ada@example.com>\n" ++
        "summary first\n" ++
        "filename f.txt\n" ++
        "\tline one\n" ++
        "\tline two\n" ++
        oid_b ++ " 2 3\n" ++
        "author Grace\n" ++
        "summary second\n" ++
        "filename f.txt\n" ++
        "\tline three\n" ++
        oid_a ++ " 3 4\n" ++
        "\tline four\n";
    var blame = try parseBlame(t.allocator, sample);
    defer blame.deinit();
    try t.expectEqual(@as(usize, 4), blame.lines.len);
    try t.expectEqualStrings(oid_a, blame.lines[0].oid);
    try t.expectEqualStrings("Ada", blame.lines[0].author);
    try t.expectEqualStrings("first", blame.lines[0].summary);
    try t.expectEqual(@as(usize, 1), blame.lines[0].line_no);
    try t.expectEqualStrings("line one", blame.lines[0].text);
    try t.expectEqual(@as(usize, 2), blame.lines[1].line_no);
    try t.expectEqualStrings("line two", blame.lines[1].text);
    try t.expectEqualStrings("Grace", blame.lines[2].author);
    try t.expectEqual(@as(usize, 3), blame.lines[2].line_no);
    // Repeated commit reuses cached metadata without re-emitting it.
    try t.expectEqualStrings("Ada", blame.lines[3].author);
    try t.expectEqualStrings("first", blame.lines[3].summary);
    try t.expectEqual(@as(usize, 4), blame.lines[3].line_no);
    try t.expectEqualStrings("line four", blame.lines[3].text);

    try t.expectError(error.InvalidRecord, parseBlame(t.allocator, "\torphan content\n"));
}

test "blame parser enforces the line budget" {
    const t = std.testing;
    const oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    try bytes.appendSlice(t.allocator, oid ++ " 1 1\nauthor A\nsummary s\n");
    for (0..max_blame_lines + 1) |_| try bytes.appendSlice(t.allocator, "\tx\n");
    try t.expectError(error.TooManyBlameLines, parseBlame(t.allocator, bytes.items));
}

test "parseWebRemote handles https/ssh/scp forms, subgroups and .git" {
    const t = std.testing;
    const gh = try parseWebRemote(t.allocator, "git@github.com:owner/repo.git");
    defer gh.deinit(t.allocator);
    try t.expectEqual(Host.github, gh.host);
    try t.expectEqualStrings("owner", gh.owner);
    try t.expectEqualStrings("repo", gh.repo);

    const gl = try parseWebRemote(t.allocator, "https://gitlab.com/group/sub/project.git");
    defer gl.deinit(t.allocator);
    try t.expectEqual(Host.gitlab, gl.host);
    try t.expectEqualStrings("group/sub", gl.owner);
    try t.expectEqualStrings("project", gl.repo);

    const cb = try parseWebRemote(t.allocator, "ssh://git@codeberg.org/owner/repo.git");
    defer cb.deinit(t.allocator);
    try t.expectEqual(Host.codeberg, cb.host);
    try t.expectEqualStrings("owner", cb.owner);

    try t.expectError(error.UnsupportedHost, parseWebRemote(t.allocator, "https://example.com/o/r.git"));
    try t.expectError(error.InvalidUrl, parseWebRemote(t.allocator, "https://github.com/onlyowner"));
    try t.expectError(error.InvalidUrl, parseWebRemote(t.allocator, "git@github.com:../repo.git"));
}

test "buildPermalink produces validated host-specific blob URLs" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const gh = try buildPermalink(t.allocator, "git@github.com:owner/repo.git", oid, "src/a b.zig", 12);
    defer t.allocator.free(gh);
    try t.expectEqualStrings("https://github.com/owner/repo/blob/" ++ oid ++ "/src/a%20b.zig#L12", gh);
    const gl = try buildPermalink(t.allocator, "https://gitlab.com/g/p.git", oid, "f.txt", 1);
    defer t.allocator.free(gl);
    try t.expectEqualStrings("https://gitlab.com/g/p/-/blob/" ++ oid ++ "/f.txt#L1", gl);
    const cb = try buildPermalink(t.allocator, "https://codeberg.org/o/r.git", oid, "f.txt", 3);
    defer t.allocator.free(cb);
    try t.expectEqualStrings("https://codeberg.org/o/r/src/commit/" ++ oid ++ "/f.txt#L3", cb);
    try t.expectError(error.InvalidOid, buildPermalink(t.allocator, "git@github.com:o/r.git", "zz", "f.txt", 1));
    try t.expectError(error.InvalidPath, buildPermalink(t.allocator, "git@github.com:o/r.git", oid, "../f", 1));
    try t.expectError(error.InvalidLine, buildPermalink(t.allocator, "git@github.com:o/r.git", oid, "f.txt", 0));
    try t.expectError(error.UnsupportedHost, buildPermalink(t.allocator, "https://example.com/o/r.git", oid, "f.txt", 1));
}

test "validateHttpsUrl rejects unsafe schemes, userinfo, controls and traversal" {
    const t = std.testing;
    try validateHttpsUrl("https://github.com/o/r/blob/abc/f.txt#L1");
    try validateHttpsUrl("https://gitlab.com:443/g/p/-/blob/abc/f#L2");
    try t.expectError(error.InvalidUrl, validateHttpsUrl("http://github.com/o/r"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("file:///etc/passwd"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("javascript:alert(1)"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://user:pass@github.com/o/r"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://github.com/o/../../etc"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://github.com/o/r\n"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://github.com/o\\r"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://github.com/o r"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl("https://\xff.com/o"));
    try t.expectError(error.InvalidUrl, validateHttpsUrl(""));
}
