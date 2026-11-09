//! Bounded, nonrecursive, worker-only Linux browsing. No symlink components are
//! followed, including ancestors of the model's canonical root. This protects
//! enumeration, not a subsequent path-based editor load against rename races.
const std = @import("std");
const fs = @import("manifest_fs.zig");
const manifest = @import("manifest.zig");
const c = @import("pearl_app_c");
const ignore = @import("ignore.zig");
const ignore_fs = @import("ignore_fs.zig");
/// Legacy ceiling, retained for source compatibility. New pages use page_limit.
pub const limit = 500;
pub const page_limit = 256;
pub const record_limit = 4096;
/// Deterministic test-only interruption; absent from production builds.
pub const TestHooks = if (@import("builtin").is_test) struct {
    pub var after_record: ?*const fn (c_int, usize, *c.GCancellable) void = null;
} else struct {};
pub const DirectoryIdentity = ignore_fs.Identity;
pub const Generation = ignore_fs.Generation;

/// Opaque, process-local Linux directory cookie, not an index or durable token.
/// Copy by value; use only with the identical root/relative/exclude inputs.
/// No descriptors or borrowed strings are retained between calls.
pub const Continuation = struct {
    cookie: c_long,
    generation: Generation,
    directory: DirectoryIdentity,
};
pub const Status = enum { ready, ignored, reset_required };
/// Work counters for ready/ignored pages (not wall-clock time). Include
/// abandoned partial matches and both policy walks. Reset pages use zeros;
/// errors return no Page. policy_bytes counts payload, not the one-byte EOF
/// probe performed per regular ignore file.
pub const Work = struct {
    match_steps: usize = 0,
    policy_match_steps: usize = 0,
    policy_bytes: usize = 0,
    policy_files: usize = 0,
};
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    continuation: ?Continuation,
    generation: Generation,
    directory: ?DirectoryIdentity,
    complete: bool,
    status: Status,
    /// Committed records, including skipped/ignored ones, <=record_limit.
    /// Does not count a candidate whose unfinished match must be retried.
    processed: usize = 0,
    /// Search-only omissions of children exceeding the root-relative path limit.
    /// scanPage retains its strict TooLarge behavior and never sets this field.
    path_omissions: usize = 0,
    work: Work = .{},

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Kind = enum { directory, file, blocked };
pub const Entry = struct { name: []const u8, kind: Kind };
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    truncated: bool,
    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

/// Join without lexical dot-dot normalization: link/.. has physical semantics.
/// Model canonicalizes available roots; missing roots keep their absolute spelling.
pub fn absolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    try manifest.validateString(path, manifest.limits.path_bytes);
    if (path[0] == '/') return allocator.dupe(u8, path);
    const cwd = c.g_get_current_dir();
    defer c.g_free(cwd);
    const result = try std.fs.path.join(allocator, &.{ std.mem.span(cwd), path });
    errdefer allocator.free(result);
    try fs.absolutePath(result);
    return result;
}

fn component(part: []const u8) !void {
    if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '/') != null) return error.OutsideRoot;
    try manifest.validateString(part, manifest.limits.path_bytes);
}

fn child(fd: c_int, name: []const u8, directory: bool) !c_int {
    try component(name);
    const z = try std.heap.c_allocator.dupeSentinel(u8, name, 0);
    defer std.heap.c_allocator.free(z);
    const result = std.c.openat(fd, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = directory, .PATH = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (result < 0) return error.UnavailableOrSymlink;
    return result;
}

fn rootDescriptor(root: []const u8, cancel: ?*c.GCancellable) !c_int {
    try fs.absolutePath(root);
    // Ancestors need search permission, never directory-listing permission.
    // O_PATH|O_DIRECTORY|O_NOFOLLOW rejects directory symlinks; the final
    // O_PATH file descriptor is separately inspected by checkFile below.
    var fd = std.c.open("/", .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.UnavailableOrSymlink;
    errdefer _ = std.c.close(fd);
    if (root.len == 1) return fd;
    var parts = std.mem.splitScalar(u8, root[1..], '/');
    while (parts.next()) |part| {
        if (cancel) |value| try ignore_fs.cancelled(value);
        const next = try child(fd, part, true);
        _ = std.c.close(fd);
        fd = next;
    }
    return fd;
}

fn walk(root: []const u8, relative: []const u8, directory: bool) !c_int {
    var fd = try rootDescriptor(root, null);
    errdefer _ = std.c.close(fd);
    if (relative.len == 0) {
        if (!directory) return error.NotRegularFile;
        return fd;
    }
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        const next = try child(fd, part, directory or parts.peek() != null);
        _ = std.c.close(fd);
        fd = next;
    }
    return fd;
}

pub fn checkFile(root: []const u8, relative: []const u8) !void {
    const fd = try walk(root, relative, false);
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE) return error.Io;
    if (stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
}

/// Worker-only incremental enumeration. Memory is O(page_limit + bounded ignore
/// policy), never O(directory size). Reads only this directory and ancestor
/// .gitignore files; never recursively scans. Each page is sorted directory/file/
/// blocked, then UTF-8 byte order, NOT globally sorted across pages. The UI should
/// sort a loaded model and virtualize rows, not instantiate 100k native widgets.
///
/// Inputs are borrowed only for this call; workers must keep them immutable and
/// alive (copy Model.exclude before dispatch if the model can close). Page is
/// move-only; deinit it after copying/consuming its entries. Tokens own no memory.
/// null continuation starts a new snapshot. An empty ready page with complete=false
/// is valid (record or shared matching budget reached); keep paging. An unfinished
/// match is retried from its PRE-record cookie, never treated as included/ignored.
/// complete=true means EOF or an
/// ignored parent. reset_required has NO entries/continuation and complete=false:
/// discard ALL previously loaded pages and start with null, never append it.
/// Cancellation/errors leave the input token reusable. Errors must be displayed,
/// especially IgnoreUnavailable/IgnoreNotRegular/IgnoreTooLarge/InvalidIgnore.
/// Per call: <=8 Mi charged enumeration steps; <=8 Mi ancestor-matching steps
/// shared across BOTH policy walks; <=512 KiB ignore payload read/parsed (+ one
/// EOF-probe byte per regular ignore file) and <=258 ignore-file probes. Existing per-snapshot storage/rule/depth caps still apply.
/// A single path exceeding 8 Mi steps fails MatchBudgetExceeded. Policy work
/// exhaustion fails PolicyBudgetExceeded, never yields a permissive listing.
/// PageBudgetExceeded is internal: it returns a ready, incomplete prefix page.
///
/// Generation hashes root/path/excludes, ancestor directory identity/mtime/ctime,
/// and ignore contents+metadata. Validate both sides of enumeration. This detects
/// normal filesystem mutations, not a transactional snapshot against hostile
/// timestamp restoration or filesystems with stale/coarse metadata. O_NONBLOCK
/// avoids FIFO hangs, not uninterruptible remote filesystem I/O. Cookies require
/// Linux seekable directories and are never persisted or reused after a reset.
/// .git (file or directory) is always hidden at every depth, even when negated.
pub fn scanPage(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, excludes: []const []const u8, continuation: ?Continuation, cancel: *c.GCancellable) !Page {
    return scanPageImpl(allocator, root, relative, excludes, continuation, cancel, false);
}

/// Same policy/generation/record bounds as scanPage, but reports overlong child
/// paths as explicit omissions and continues to valid siblings. This does NOT
/// soften invalid request, exclude, or ignore-policy errors. Tokens must stay
/// within the API that issued them; explorer scanPage remains strict.
pub fn scanSearchPage(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, excludes: []const []const u8, continuation: ?Continuation, cancel: *c.GCancellable) !Page {
    return scanPageImpl(allocator, root, relative, excludes, continuation, cancel, true);
}

fn scanPageImpl(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, excludes: []const []const u8, continuation: ?Continuation, cancel: *c.GCancellable, comptime omit_overlong_children: bool) !Page {
    try validateRequest(root, relative, excludes);
    try ignore_fs.cancelled(cancel);
    var policy_work = PolicyWork{ .matching = .{ .remaining = ignore.limits.policy_match_steps, .kind = .policy, .cancellation = ignore_fs.cancellation(cancel) } };
    var matching = ignore.Budget{ .remaining = ignore.limits.page_match_steps, .kind = .page, .cancellation = ignore_fs.cancellation(cancel) };
    var policy = loadPolicy(allocator, root, relative, excludes, cancel, &policy_work) catch |err| {
        if (err == error.DirectoryChanged) return resetPage(allocator);
        // A removed/replaced traversal target invalidates a previously issued cookie.
        if (continuation != null and err == error.UnavailableOrSymlink) return resetPage(allocator);
        return err;
    };
    defer policy.deinit();
    const identity = ignore_fs.identity(try ignore_fs.inspect(policy.fd));
    if (continuation) |previous| {
        if (policy.hidden or !std.mem.eql(u8, &previous.generation, &policy.generation) or !std.meta.eql(previous.directory, identity)) return resetPage(allocator);
    }
    if (policy.hidden) return .{ .arena = .init(allocator), .entries = &.{}, .continuation = null, .generation = policy.generation, .directory = null, .complete = true, .status = .ignored, .work = policy_work.report(&matching) };
    // Reopen the pinned final O_PATH directory, never its original pathname.
    const fd = std.c.openat(policy.fd, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.UnavailableOrSymlink;
    const dir = std.c.fdopendir(fd) orelse {
        _ = std.c.close(fd);
        return error.Io;
    };
    defer _ = std.c.closedir(dir);
    if (continuation) |previous| {
        // On Linux libc telldir/seekdir expose the filesystem's opaque d_off
        // cookie, valid on a reopened unchanged directory (not a row offset).
        std.c._errno().* = 0;
        std.c.seekdir(dir, previous.cookie);
        if (std.c._errno().* != 0) return error.UnsupportedCookie;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(Entry, page_limit);
    var count: usize = 0;
    var processed: usize = 0;
    var path_omissions: usize = 0;
    var complete = false;
    var retry_cookie: ?c_long = null;
    var path_buffer: [manifest.limits.path_bytes]u8 = undefined;
    while (count < page_limit and processed < record_limit) {
        try ignore_fs.cancelled(cancel);
        const before_record = try directoryCookie(dir);
        std.c._errno().* = 0;
        const raw = std.c.readdir(dir) orelse {
            if (std.c.errno(@as(c_int, -1)) != .SUCCESS) return error.Io;
            complete = true;
            break;
        };
        processed += 1;
        if (@import("builtin").is_test) {
            if (TestHooks.after_record) |hook| hook(fd, processed, cancel);
        }
        try ignore_fs.cancelled(cancel);
        const name = std.mem.sliceTo(&raw.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".git")) continue;
        const path_len = relative.len + @intFromBool(relative.len != 0) + name.len;
        if (path_len > path_buffer.len) {
            if (!omit_overlong_children) return error.TooLarge;
            path_omissions += 1;
            continue;
        }
        @memcpy(path_buffer[0..relative.len], relative);
        var offset = relative.len;
        if (offset > 0) {
            path_buffer[offset] = '/';
            offset += 1;
        }
        @memcpy(path_buffer[offset..path_len], name);
        var stat: std.os.linux.Statx = undefined;
        const kind: Kind = if (std.c.statx(fd, @ptrCast(&raw.name), std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE) .blocked else switch (stat.mode & std.c.S.IFMT) {
            std.c.S.IFDIR => .directory,
            std.c.S.IFREG => .file,
            else => .blocked,
        };
        try ignore_fs.cancelled(cancel);
        const path = path_buffer[0..path_len];
        try matching.beginPath();
        const hidden = hiddenByPolicy(&policy.rules, excludes, path, kind == .directory, &matching) catch |err| {
            if (err != error.PageBudgetExceeded) return err;
            // The DIR may already have read ahead internally. Return the cookie
            // from BEFORE this candidate, not telldir's current position. Its
            // classification was not completed and MUST be retried next call.
            std.debug.assert(processed > 1);
            processed -= 1;
            retry_cookie = before_record;
            break;
        };
        if (hidden) continue;
        const valid = std.unicode.utf8ValidateSlice(name);
        entries[count] = .{ .name = try a.dupe(u8, if (valid) name else "[unsupported filename encoding]"), .kind = if (valid) kind else .blocked };
        count += 1;
    }
    const cookie = retry_cookie orelse try directoryCookie(dir);
    // Rewalk from the root to detect pathname replacement as well as changes to
    // the pinned descriptor or any ancestor's policy. No entry escapes on drift.
    var after = loadPolicy(allocator, root, relative, excludes, cancel, &policy_work) catch |err| {
        if (err == error.DirectoryChanged or err == error.UnavailableOrSymlink) {
            arena.deinit();
            return resetPage(allocator);
        }
        return err;
    };
    defer after.deinit();
    if (after.hidden or !std.mem.eql(u8, &policy.generation, &after.generation)) {
        arena.deinit();
        return resetPage(allocator);
    }
    try ignore_fs.cancelled(cancel);
    std.mem.sort(Entry, entries[0..count], {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    return .{ .arena = arena, .entries = entries[0..count], .continuation = if (complete) null else .{ .cookie = cookie, .generation = policy.generation, .directory = identity }, .generation = policy.generation, .directory = identity, .complete = complete, .status = .ready, .processed = processed, .path_omissions = path_omissions, .work = policy_work.report(&matching) };
}

/// Worker-only checked-read boundary for search. Retains a descriptor and the
/// existing browser policy; callers must validate before publishing a batch.
/// Work is added on success AND failure, rather than reserving a page per file.
/// No pathname-based read may follow openFile: consume the returned descriptor.
pub const CheckedDirectory = struct {
    policy: Policy,
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
    excludes: []const []const u8,
    cancel: *c.GCancellable,

    pub fn open(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, excludes: []const []const u8, expected: ?Generation, cancel: *c.GCancellable, work: *Work) !CheckedDirectory {
        try validateRequest(root, relative, excludes);
        var pw = PolicyWork{ .matching = .{ .remaining = ignore.limits.policy_match_steps, .kind = .policy, .cancellation = ignore_fs.cancellation(cancel) } };
        defer addWork(work, pw.report(&.{ .remaining = ignore.limits.page_match_steps }));
        var policy = try loadPolicy(allocator, root, relative, excludes, cancel, &pw);
        errdefer policy.deinit();
        if (expected) |expected_generation| {
            if (policy.hidden or !std.mem.eql(u8, &expected_generation, &policy.generation)) return error.DirectoryChanged;
        }
        return .{ .policy = policy, .allocator = allocator, .root = root, .relative = relative, .excludes = excludes, .cancel = cancel };
    }

    pub fn deinit(self: *CheckedDirectory) void {
        self.policy.deinit();
        self.* = undefined;
    }

    pub fn generation(self: *const CheckedDirectory) Generation {
        return self.policy.generation;
    }

    pub fn hidden(self: *const CheckedDirectory) bool {
        return self.policy.hidden;
    }

    pub fn validate(self: *CheckedDirectory, work: *Work) !void {
        var after = open(self.allocator, self.root, self.relative, self.excludes, null, self.cancel, work) catch |err| {
            if (err == error.UnavailableOrSymlink) return error.DirectoryChanged;
            return err;
        };
        defer after.deinit();
        if (after.policy.hidden != self.policy.hidden or !std.mem.eql(u8, &after.policy.generation, &self.policy.generation)) return error.DirectoryChanged;
    }

    /// Includes hypothetical missing leaves, but never symlinks or special files.
    pub fn allowsOverlay(self: *CheckedDirectory, name: []const u8, work: *Work) !bool {
        try component(name);
        try ignore_fs.cancelled(self.cancel);
        if (self.policy.hidden or std.mem.eql(u8, name, ".git")) return false;
        var buffer: [manifest.limits.path_bytes + 1]u8 = undefined;
        const path = if (self.relative.len == 0) name else try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.relative, name });
        var matching = ignore.Budget{ .remaining = ignore.limits.page_match_steps, .kind = .page, .cancellation = ignore_fs.cancellation(self.cancel) };
        defer work.match_steps += ignore.limits.page_match_steps - matching.remaining;
        try matching.beginPath();
        if (try hiddenByPolicy(&self.policy.rules, self.excludes, path, false, &matching)) return false;
        var leaf: [manifest.limits.path_bytes + 1]u8 = undefined;
        const z = try std.fmt.bufPrintSentinel(&leaf, "{s}", .{name}, 0);
        var stat: std.os.linux.Statx = undefined;
        if (std.c.statx(self.policy.fd, z, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stat) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .NOENT) return true;
            return error.UnavailableOrSymlink;
        }
        if (!stat.mask.TYPE or stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
        return true;
    }

    /// name must be a file from a page with this generation, or an allowed leaf.
    /// Caller owns fd; NOFOLLOW applies to the leaf, ancestors are already pinned.
    pub fn openFile(self: *CheckedDirectory, name: []const u8) !c_int {
        try component(name);
        try ignore_fs.cancelled(self.cancel);
        if (self.policy.hidden) return error.OutsideRoot;
        var buffer: [manifest.limits.path_bytes + 1]u8 = undefined;
        const z = try std.fmt.bufPrintSentinel(&buffer, "{s}", .{name}, 0);
        const fd = std.c.openat(self.policy.fd, z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return error.UnavailableOrSymlink;
        errdefer _ = std.c.close(fd);
        const stat = try ignore_fs.inspect(fd);
        if (stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
        return fd;
    }
};

fn addWork(total: *Work, work: Work) void {
    total.match_steps += work.match_steps;
    total.policy_match_steps += work.policy_match_steps;
    total.policy_bytes += work.policy_bytes;
    total.policy_files += work.policy_files;
}

fn directoryCookie(dir: *std.c.DIR) !c_long {
    std.c._errno().* = 0;
    const cookie = std.c.telldir(dir);
    if (cookie == -1 or std.c._errno().* != 0) return error.UnsupportedCookie;
    return cookie;
}

fn hiddenByPolicy(rules: *const ignore.Rules, excludes: []const []const u8, path: []const u8, directory: bool, budget: *ignore.Budget) !bool {
    return try ignore.excludedBudget(excludes, path, directory, budget) or try rules.ignoredBudget(path, directory, budget);
}

fn resetPage(allocator: std.mem.Allocator) Page {
    return .{ .arena = .init(allocator), .entries = &.{}, .continuation = null, .generation = @splat(0), .directory = null, .complete = false, .status = .reset_required };
}

/// Compatibility only: returns the first page. truncated means more pages exist,
/// not that the backend has a terminal 500-entry cap. New callers use scanPage.
pub fn scan(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, cancel: *c.GCancellable) !Listing {
    var page = try scanPage(allocator, root, relative, &.{}, null, cancel);
    if (page.status == .reset_required) {
        page.deinit();
        return error.DirectoryChanged;
    }
    return .{ .arena = page.arena, .entries = page.entries, .truncated = !page.complete };
}

fn validateRequest(root: []const u8, relative: []const u8, excludes: []const []const u8) !void {
    try fs.absolutePath(root);
    if (relative.len > manifest.limits.path_bytes) return error.TooLarge;
    if (relative.len != 0) {
        var parts = std.mem.splitScalar(u8, relative, '/');
        var depth: usize = 0;
        while (parts.next()) |part| {
            try component(part);
            depth += 1;
            if (depth > ignore.limits.depth) return error.IgnoreTooLarge;
        }
    }
    if (excludes.len > ignore.limits.excludes) return error.TooLarge;
    for (excludes) |pattern| {
        try manifest.validateString(pattern, ignore.limits.pattern_bytes);
        try ignore.validateExclude(pattern);
    }
}

const Policy = struct {
    fd: c_int,
    rules: ignore.Rules,
    generation: Generation,
    hidden: bool,
    fn deinit(self: *Policy) void {
        _ = std.c.close(self.fd);
        self.rules.deinit();
    }
};

const PolicyWork = struct {
    matching: ignore.Budget,
    bytes: usize = 0,
    files: usize = 0,

    fn report(self: *const PolicyWork, matching: *const ignore.Budget) Work {
        return .{
            .match_steps = ignore.limits.page_match_steps - matching.remaining,
            .policy_match_steps = ignore.limits.policy_match_steps - self.matching.remaining,
            .policy_bytes = self.bytes,
            .policy_files = self.files,
        };
    }
};

fn loadPolicy(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, excludes: []const []const u8, cancel: *c.GCancellable, work: *PolicyWork) !Policy {
    var hash = ignore_fs.Hash.init(.{});
    ignore_fs.field(&hash, "coral-browser-generation-v1");
    ignore_fs.field(&hash, root);
    ignore_fs.field(&hash, relative);
    const exclude_count: u64 = excludes.len;
    hash.update(std.mem.asBytes(&exclude_count));
    for (excludes) |pattern| ignore_fs.field(&hash, pattern);
    var fd = try rootDescriptor(root, cancel);
    errdefer _ = std.c.close(fd);
    var rules = ignore.Rules{ .allocator = allocator };
    errdefer rules.deinit();
    var prefix: usize = 0;
    var hidden = false;
    while (true) {
        try ignore_fs.cancelled(cancel);
        const before = try ignore_fs.inspect(fd);
        ignore_fs.stamp(&hash, before);
        if (work.files == ignore.limits.policy_files) return error.PolicyBudgetExceeded;
        work.files += 1;
        const source_left = @min(ignore.limits.total_bytes - rules.bytes, ignore.limits.policy_read_bytes - work.bytes);
        if (try ignore_fs.read(allocator, fd, &hash, cancel, source_left)) |bytes| {
            defer allocator.free(bytes);
            work.bytes += bytes.len;
            try rules.appendCancellable(relative[0..prefix], bytes, ignore_fs.cancellation(cancel));
        }
        if (!ignore_fs.same(before, try ignore_fs.inspect(fd))) return error.DirectoryChanged;
        if (prefix == relative.len) break;
        const start = prefix + @intFromBool(prefix != 0);
        const end = if (std.mem.indexOfScalarPos(u8, relative, start, '/')) |i| i else relative.len;
        const name = relative[start..end];
        try work.matching.beginPath();
        if (std.mem.eql(u8, name, ".git") or try hiddenByPolicy(&rules, excludes, relative[0..end], true, &work.matching)) {
            hidden = true;
            break;
        }
        try ignore_fs.cancelled(cancel);
        const next = try child(fd, name, true);
        _ = std.c.close(fd);
        fd = next;
        prefix = end;
    }
    return .{ .fd = fd, .rules = rules, .generation = hash.finalResult(), .hidden = hidden };
}

test "browser traverses execute-only ancestors but requires a readable final scan directory" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const temp = c.g_dir_make_tmp("coral-browser-permissions-XXXXXX", null) orelse return error.TempDirectory;
    defer c.g_free(temp);
    defer _ = c.g_rmdir(temp);
    const parent = try std.fmt.allocPrintSentinel(a, "{s}/search-only", .{std.mem.span(temp)}, 0);
    defer a.free(parent);
    const root = try std.fmt.allocPrintSentinel(a, "{s}/readable", .{parent}, 0);
    defer a.free(root);
    const middle = try std.fmt.allocPrintSentinel(a, "{s}/middle", .{root}, 0);
    defer a.free(middle);
    const leaf = try std.fmt.allocPrintSentinel(a, "{s}/leaf", .{middle}, 0);
    defer a.free(leaf);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/file.txt", .{leaf}, 0);
    defer a.free(file);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(parent, 0o700));
    defer _ = c.g_rmdir(parent);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(root, 0o700));
    defer _ = c.g_rmdir(root);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(middle, 0o700));
    defer _ = c.g_rmdir(middle);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(leaf, 0o700));
    defer _ = c.g_rmdir(leaf);
    try std.testing.expect(c.g_file_set_contents(file, "test", 4, null) != 0);
    defer _ = c.g_unlink(file);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(parent, 0o111));
    defer _ = std.c.chmod(parent, 0o700);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(middle, 0o111));
    defer _ = std.c.chmod(middle, 0o700);
    const denied = std.c.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer if (denied >= 0) {
        _ = std.c.close(denied);
    };
    try std.testing.expect(denied < 0);
    try std.testing.expectEqual(std.c.E.ACCES, std.c.errno(denied));
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var top = try scan(a, root, "", cancel);
    defer top.deinit();
    try std.testing.expectEqualStrings("middle", top.entries[0].name);
    var nested = try scan(a, root, "middle/leaf", cancel);
    defer nested.deinit();
    try std.testing.expectEqualStrings("file.txt", nested.entries[0].name);
    try checkFile(root, "middle/leaf/file.txt");
    try std.testing.expectError(error.UnavailableOrSymlink, scan(a, root, "middle", cancel));
}

test {
    _ = @import("browser_fs_test.zig");
}

test "browser components reject lexical escapes" {
    try std.testing.expectError(error.OutsideRoot, component(".."));
    try std.testing.expectError(error.OutsideRoot, component("."));
    try std.testing.expectError(error.OutsideRoot, component("/outside"));
    try std.testing.expectError(error.OutsideRoot, component("a/b"));
    try component("normal file");
}
