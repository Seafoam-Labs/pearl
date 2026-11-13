//! Persistent thread storage under XDG state/coral/agents using atomic JSON.
//!
//! Each thread is one JSON file written to a temporary sibling and renamed
//! into place, so a crash never leaves a partial thread file. Restoration
//! skips unreadable/corrupt files rather than failing the whole load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const auth = @import("auth.zig");

pub const PersistedMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const PersistedThread = struct {
    version: u32 = 1,
    id: []const u8,
    title: []const u8 = "",
    provider: []const u8 = "fake",
    model: []const u8 = "",
    state: []const u8 = "idle",
    worktree_root: ?[]const u8 = null,
    worktree_branch: ?[]const u8 = null,
    acp_argv: ?[]const []const u8 = null,
    messages: []const PersistedMessage = &.{},
    created_ms: i64 = 0,
    updated_ms: i64 = 0,
};

pub fn freeThread(allocator: Allocator, t: PersistedThread) void {
    allocator.free(t.id);
    allocator.free(t.title);
    allocator.free(t.provider);
    allocator.free(t.model);
    allocator.free(t.state);
    if (t.worktree_root) |w| allocator.free(w);
    if (t.worktree_branch) |w| allocator.free(w);
    if (t.acp_argv) |argv| {
        for (argv) |s| allocator.free(s);
        allocator.free(argv);
    }
    for (t.messages) |m| {
        allocator.free(m.role);
        allocator.free(m.content);
        if (m.tool_call_id) |x| allocator.free(x);
        if (m.name) |x| allocator.free(x);
    }
    allocator.free(t.messages);
}

fn dupeThread(allocator: Allocator, src: PersistedThread) !PersistedThread {
    var out: PersistedThread = .{
        .version = src.version,
        .id = try allocator.dupe(u8, src.id),
        .title = try allocator.dupe(u8, src.title),
        .provider = try allocator.dupe(u8, src.provider),
        .model = try allocator.dupe(u8, src.model),
        .state = try allocator.dupe(u8, src.state),
        .created_ms = src.created_ms,
        .updated_ms = src.updated_ms,
    };
    errdefer freeThread(allocator, out);
    out.worktree_root = if (src.worktree_root) |w| try allocator.dupe(u8, w) else null;
    out.worktree_branch = if (src.worktree_branch) |w| try allocator.dupe(u8, w) else null;
    if (src.acp_argv) |argv| {
        const copy = try allocator.alloc([]const u8, argv.len);
        for (argv, 0..) |s, i| copy[i] = try allocator.dupe(u8, s);
        out.acp_argv = copy;
    }
    const msgs = try allocator.alloc(PersistedMessage, src.messages.len);
    for (src.messages, 0..) |m, i| {
        msgs[i] = .{
            .role = try allocator.dupe(u8, m.role),
            .content = try allocator.dupe(u8, m.content),
            .tool_call_id = if (m.tool_call_id) |x| try allocator.dupe(u8, x) else null,
            .name = if (m.name) |x| try allocator.dupe(u8, x) else null,
        };
    }
    out.messages = msgs;
    return out;
}

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    dir_path: []u8,
    counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Create (if needed) and open the state directory.
    pub fn init(allocator: Allocator, io: Io, dir_path: []const u8) !Store {
        try Io.Dir.cwd().createDirPath(io, dir_path);
        const dir = try Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .dir_path = try allocator.dupe(u8, dir_path),
        };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
        self.allocator.free(self.dir_path);
    }

    /// Atomically persist a thread: write a temp sibling, then rename.
    pub fn save(self: *Store, t: PersistedThread) !void {
        const a = self.allocator;
        const json = try std.json.Stringify.valueAlloc(a, t, .{ .emit_null_optional_fields = false });
        defer a.free(json);

        const seq = self.counter.fetchAdd(1, .monotonic);
        const tmp_name = try std.fmt.allocPrint(a, "{s}.tmp-{d}", .{ t.id, seq });
        defer a.free(tmp_name);
        const final_name = try std.fmt.allocPrint(a, "{s}.json", .{t.id});
        defer a.free(final_name);

        var file = try self.dir.createFile(self.io, tmp_name, .{});
        var buf: [4096]u8 = undefined;
        var writer = file.writer(self.io, &buf);
        writer.interface.writeAll(json) catch |err| {
            file.close(self.io);
            self.dir.deleteFile(self.io, tmp_name) catch {};
            return err;
        };
        writer.end() catch |err| {
            file.close(self.io);
            self.dir.deleteFile(self.io, tmp_name) catch {};
            return err;
        };
        file.close(self.io);
        self.dir.rename(tmp_name, self.dir, final_name, self.io) catch |err| {
            self.dir.deleteFile(self.io, tmp_name) catch {};
            return err;
        };
    }

    /// Load every valid thread file. Corrupt files are skipped.
    pub fn loadAll(self: *Store, allocator: Allocator) ![]PersistedThread {
        var list: std.ArrayList(PersistedThread) = .empty;
        errdefer {
            for (list.items) |t| freeThread(allocator, t);
            list.deinit(allocator);
        }
        var it = self.dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const bytes = self.dir.readFileAlloc(self.io, entry.name, allocator, .limited(4 * 1024 * 1024)) catch continue;
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(PersistedThread, allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            const owned = dupeThread(allocator, parsed.value) catch continue;
            try list.append(allocator, owned);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn remove(self: *Store, id: []const u8) !void {
        const name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{id});
        defer self.allocator.free(name);
        self.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

/// Default state directory honoring XDG: $XDG_STATE_HOME/coral/agents or
/// ~/.local/state/coral/agents. Caller owns the result.
pub fn defaultStateDir(allocator: Allocator, env: auth.Env) ![]u8 {
    if (env.lookup("XDG_STATE_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "coral", "agents" });
    }
    const home = env.lookup("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "coral", "agents" });
}

test "save/load round trip is atomic and restores messages" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);

    var store = try Store.init(a, io, path);
    defer store.deinit();

    const msgs = [_]PersistedMessage{.{ .role = "user", .content = "hello" }};
    try store.save(.{ .id = "t1", .title = "Thread 1", .provider = "fake", .messages = &msgs, .worktree_root = "/wt" });

    // No temp files left behind.
    var it = store.dir.iterate();
    var json_count: usize = 0;
    while (try it.next(io)) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.name, ".tmp-") == null);
        if (std.mem.endsWith(u8, e.name, ".json")) json_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), json_count);

    const loaded = try store.loadAll(a);
    defer {
        for (loaded) |t| freeThread(a, t);
        a.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("t1", loaded[0].id);
    try std.testing.expectEqualStrings("/wt", loaded[0].worktree_root.?);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].messages.len);
    try std.testing.expectEqualStrings("hello", loaded[0].messages[0].content);
}

test "corrupt thread files are skipped" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var store = try Store.init(a, io, path);
    defer store.deinit();

    try store.save(.{ .id = "good", .title = "G" });
    try store.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{not valid json" });

    const loaded = try store.loadAll(a);
    defer {
        for (loaded) |t| freeThread(a, t);
        a.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("good", loaded[0].id);
}

test "defaultStateDir honors XDG_STATE_HOME" {
    const a = std.testing.allocator;
    const Fake = struct {
        fn get(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "XDG_STATE_HOME")) return "/state";
            return null;
        }
    };
    const p = try defaultStateDir(a, .{ .get = Fake.get });
    defer a.free(p);
    try std.testing.expectEqualStrings("/state/coral/agents", p);
}
