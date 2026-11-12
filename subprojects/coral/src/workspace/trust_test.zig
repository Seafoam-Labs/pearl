//! Standalone headless tests: zig test trust_test.zig -lc. No GTK or test-root
//! integration required. Fork tests must run without an application worker pool.
const std = @import("std");
const trust = @import("trust.zig");
const fs = @import("trust_fs.zig");
const routing = @import("identity.zig");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn alarm(seconds: c_uint) c_uint;

fn key(n: u32) trust.Fingerprint {
    var result: trust.Fingerprint = @splat(0);
    std.mem.writeInt(u32, result[0..4], n, .little);
    return result;
}
const Home = struct {
    fixture: Fixture,
    home: fs.StateHome,
    root: [:0]u8,
    store: [:0]u8,
    dir: [:0]u8,

    fn init() !Home {
        var f = try Fixture.init();
        errdefer f.deinit();
        try f.mkdir("project");
        try f.mkdir("state");
        try f.mkdir("state/coral");
        try f.mkdir("state/coral/trust");
        const empty: trust.Records = .{};
        const bytes = try empty.encode(a);
        defer a.free(bytes);
        try f.write("state/coral/trust/store", bytes);
        const state_path = try f.path("state");
        defer a.free(state_path);
        var home = try fs.StateHome.init(a, state_path);
        errdefer home.deinit();
        const root = try f.path("project");
        errdefer a.free(root);
        const store = try f.path("state/coral/trust/store");
        errdefer a.free(store);
        return .{ .fixture = f, .home = home, .root = root, .store = store, .dir = try f.path("state/coral/trust") };
    }
    fn deinit(self: *Home) void {
        for ([_][]const u8{ "pending", "uncertain" }) |name| {
            const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.dir, name }, 0) catch unreachable;
            defer a.free(path);
            _ = std.c.unlink(path);
        }
        self.home.deinit();
        a.free(self.root);
        a.free(self.store);
        a.free(self.dir);
        self.fixture.deinit();
    }
    fn inputs(self: *Home, digest: u32) !trust.Inputs {
        return trust.Inputs.init(a, .{ .roots = &.{self.root}, .policy_digest = key(digest) });
    }
    fn overwrite(self: *Home, bytes: []const u8) !void {
        const fd = std.c.open(self.store, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try expect(n > 0);
            offset += @intCast(n);
        }
    }
};
fn chmod(path: [:0]const u8, mode: std.c.mode_t) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.fchmod(fd, mode));
}

test "always-trusted default, capability specificity, and stale completion invalidation" {
    var scope = routing.Scope.init();
    var other = routing.Scope.init();
    var policy = trust.Policy.init(scope.capture().?);
    try equal(trust.State.trusted, policy.state);
    // No consent: every capability issues immediately, without any approval.
    inline for (std.meta.tags(trust.Capability)) |capability| {
        const permit = try policy.issue(capability);
        try expect(policy.validate(permit, scope.capture().?, capability));
        try expect(!policy.validate(permit, other.capture().?, capability));
    }
    const task = try policy.issue(.tasks);
    try expect(!policy.validate(task, scope.capture().?, .agent_tools));
    // begin() retires earlier permits for stale-work invalidation, not trust.
    const first = try policy.begin(scope.capture().?);
    try expect(!policy.validate(task, scope.capture().?, .tasks));
    try expect(policy.complete(first));
    try expect(!policy.complete(first)); // consumed
    const pending = try policy.begin(scope.capture().?);
    const current = try policy.issue(.tasks);
    try expect(policy.validate(current, scope.capture().?, .tasks));
    try expect(policy.complete(pending));
    try expect(!policy.validate(current, scope.capture().?, .tasks)); // completion retires prior permits
    try expect(!policy.complete(first)); // stale ticket never completes
    const permit = try policy.issue(.lsp);
    scope.invalidate();
    try expect(!policy.validate(permit, scope.capture().?, .lsp));
    _ = try policy.begin(scope.capture().?);
    try expect(!policy.validate(permit, scope.capture().?, .lsp));
    const fresh = try policy.issue(.lsp);
    try expect(policy.validate(fresh, scope.capture().?, .lsp));
    policy.generation = std.math.maxInt(u64);
    try expectError(error.GenerationExhausted, policy.begin(scope.capture().?));
    try expectError(error.GenerationExhausted, policy.issue(.lsp));
}

test "strict store roundtrip, checksum, version, lengths, duplicate keys and caps" {
    var records: trust.Records = .{};
    for (0..trust.limits.records) |n| try records.approve(key(@intCast(n)));
    try records.approve(key(1));
    try expectError(error.StoreFull, records.approve(key(1000)));
    const bytes = try records.encode(a);
    defer a.free(bytes);
    const decoded = try trust.Records.decode(bytes);
    try equal(trust.limits.records, decoded.len);
    for (0..trust.limits.records) |n| try expect(decoded.contains(key(@intCast(n))));
    try expectError(error.CorruptStore, trust.Records.decode(""));
    try expectError(error.CorruptStore, trust.Records.decode(bytes[0 .. bytes.len - 1]));
    const extra = try a.alloc(u8, bytes.len + 1);
    defer a.free(extra);
    @memcpy(extra[0..bytes.len], bytes);
    extra[bytes.len] = 0;
    try expectError(error.CorruptStore, trust.Records.decode(extra));
    bytes[bytes.len - 1] ^= 1;
    try expectError(error.CorruptStore, trust.Records.decode(bytes));
    bytes[bytes.len - 1] ^= 1;
    bytes["CORAL-TRUST\x00".len] = 2;
    try expectError(error.UnsupportedVersion, trust.Records.decode(bytes));
    records.len = 2;
    records.keys[1] = records.keys[0];
    const duplicate = try records.encode(a);
    defer a.free(duplicate);
    try expectError(error.CorruptStore, trust.Records.decode(duplicate));
    const huge = try a.alloc(u8, trust.limits.store_bytes + 1);
    defer a.free(huge);
    try expectError(error.TooLarge, trust.Records.decode(huge));
    records.len = 1;
    records.revoke(key(0));
    try equal(@as(usize, 0), records.len);
}

test "immutable bounded input, invalid native paths and state traversal" {
    for ([_][]const u8{ "", "relative", "/nul\x00bad", "/bad\xff" }) |path| {
        try expectError(error.InvalidPath, trust.Inputs.init(a, .{ .roots = &.{path}, .policy_digest = key(0) }));
    }
    for ([_][]const u8{ "relative", "/tmp/../state", "/tmp/./state", "/tmp//state", "/tmp/state/" }) |path| {
        try expectError(error.InvalidPath, fs.StateHome.init(a, path));
    }
    const long = try a.alloc(u8, trust.limits.path_bytes + 1);
    defer a.free(long);
    @memset(long, 'x');
    long[0] = '/';
    try expectError(error.InvalidPath, trust.Inputs.init(a, .{ .roots = &.{long}, .policy_digest = key(0) }));
    try expectError(error.InvalidRoots, trust.Inputs.init(a, .{ .roots = &.{}, .policy_digest = key(0) }));
    const roots: [trust.limits.roots + 1][]const u8 = @splat("/tmp");
    try expectError(error.InvalidRoots, trust.Inputs.init(a, .{ .roots = &roots, .policy_digest = key(0) }));
    var mutable = [_]u8{ '/', 't', 'm', 'p' };
    var owned = try trust.Inputs.init(a, .{ .roots = &.{&mutable}, .policy_digest = key(1) });
    defer owned.deinit();
    mutable[1] = 'x';
    try std.testing.expectEqualStrings("/tmp", owned.value.roots[0]);
}

test "explicit approval restores identical scope, policy changes reset and revoke persists" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    const before = try fs.load(a, &h.home, &input);
    try equal(.restricted, before.state);
    try expectError(error.ScopeChanged, fs.approve(a, &h.home, &input, key(999), .user_approved));
    const approved = try fs.approve(a, &h.home, &input, before.fingerprint, .user_approved);
    try equal(.trusted, approved.state);
    var reopened = try h.inputs(1);
    defer reopened.deinit();
    try equal(.trusted, (try fs.load(a, &h.home, &reopened)).state);
    try equal(.trusted, (try fs.revalidate(a, &h.home, &input, approved.fingerprint)).state);
    try equal(.restricted, (try fs.revalidate(a, &h.home, &input, key(999))).state);
    var changed = try h.inputs(2); // includes changes in settings/excludes
    defer changed.deinit();
    try equal(.restricted, (try fs.load(a, &h.home, &changed)).state);
    try expectError(error.ScopeChanged, fs.approve(a, &h.home, &changed, approved.fingerprint, .user_approved));
    try fs.revoke(a, &h.home, approved.fingerprint);
    try equal(.restricted, (try fs.load(a, &h.home, &input)).state);
    // No .coral/settings.json or manifest was created for any of these operations.
}

test "readable workspace under execute-only ancestor captures approves and revalidates unprivileged" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var h = try Home.init();
    defer h.deinit();
    try h.fixture.mkdir("project/child");
    const root = try h.fixture.path("project/child");
    defer a.free(root);
    const manifest = try h.fixture.path("project/absent.coral-workspace");
    defer a.free(manifest);

    // Retain a descriptor solely for restoring permissions, even on assertion
    // failure; the path-based chmod helper cannot read an execute-only directory.
    const parent_fd = std.c.open(h.root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(parent_fd >= 0);
    defer _ = std.c.close(parent_fd);
    try equal(@as(c_int, 0), std.c.fchmod(parent_fd, 0o100));
    defer std.debug.assert(std.c.fchmod(parent_fd, 0o700) == 0);
    const denied = std.c.open(h.root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (denied >= 0) _ = std.c.close(denied);
    try expect(denied < 0);
    try equal(std.c.E.ACCES, std.c.errno(denied));
    const readable = std.c.open(root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(readable >= 0);
    _ = std.c.close(readable);

    // Cover both folder scopes and a manifest whose lexical base is itself the
    // execute-only ancestor. The separate machine-state tree stays owner-private.
    for ([_]bool{ false, true }) |with_manifest| {
        var input = try trust.Inputs.init(a, .{
            .manifest_path = if (with_manifest) manifest else null,
            .roots = if (with_manifest) &.{"child"} else &.{root},
            .policy_digest = key(1),
        });
        defer input.deinit();
        var identity = try fs.capture(a, &input);
        defer identity.deinit();
        try std.testing.expectEqualStrings(root, identity.roots[0].canonical);
        const approved = try fs.approve(a, &h.home, &input, identity.fingerprint, .user_approved);
        try equal(.trusted, approved.state);
        try equal(.trusted, (try fs.revalidate(a, &h.home, &input, identity.fingerprint)).state);
        var again = try fs.capture(a, &input);
        defer again.deinit();
        try equal(identity.roots[0].birth_time, again.roots[0].birth_time);
        if (with_manifest) try equal(identity.manifest_base.?.birth_time, again.manifest_base.?.birth_time);
    }
}

test "same dev/inode with a different birth time never inherits root or base approval" {
    const original: trust.Directory = .{
        .lexical = "/workspace",
        .canonical = "/workspace",
        .dev_major = 8,
        .dev_minor = 1,
        .inode = 123,
        .birth_time = .{ .seconds = 1_700_000_000, .nanoseconds = 123_456_789 },
    };
    const root_key = trust.fingerprint(null, &.{original}, key(1));
    const base_key = trust.fingerprint(original, &.{original}, key(1));
    var records: trust.Records = .{};
    try records.approve(root_key);
    try records.approve(base_key);
    for ([_]trust.BirthTime{
        .{ .seconds = original.birth_time.seconds + 1, .nanoseconds = original.birth_time.nanoseconds },
        .{ .seconds = original.birth_time.seconds, .nanoseconds = original.birth_time.nanoseconds + 1 },
        .{ .seconds = -1, .nanoseconds = original.birth_time.nanoseconds },
    }) |incarnation| {
        var replacement = original;
        replacement.birth_time = incarnation;
        try expect(!records.contains(trust.fingerprint(null, &.{replacement}, key(1))));
        try expect(!records.contains(trust.fingerprint(replacement, &.{original}, key(1))));
    }
    try expect(records.contains(trust.fingerprint(null, &.{original}, key(1))));
}

test "missing birth-time support fails closed even with populated fields" {
    var stat = std.mem.zeroes(std.os.linux.Statx);
    stat.btime.sec = 1_700_000_000;
    stat.btime.nsec = 42;
    try expectError(error.UnsupportedBirthTime, fs.directoryBirthTime(stat));
    stat.mask.BTIME = true;
    try equal(trust.BirthTime{ .seconds = stat.btime.sec, .nanoseconds = stat.btime.nsec }, try fs.directoryBirthTime(stat));
    stat.btime.nsec = 1_000_000_000;
    try expectError(error.InvalidBirthTime, fs.directoryBirthTime(stat));
}

test "unsupported procfs roots and manifest bases return explicit errors" {
    var h = try Home.init();
    defer h.deinit();
    var input = try trust.Inputs.init(a, .{ .roots = &.{"/proc"}, .policy_digest = key(1) });
    defer input.deinit();
    try expectError(error.UnsupportedBirthTime, fs.capture(a, &input));
    try expectError(error.UnsupportedBirthTime, fs.load(a, &h.home, &input));
    try expectError(error.UnsupportedBirthTime, fs.approve(a, &h.home, &input, key(1), .user_approved));
    var base_input = try trust.Inputs.init(a, .{ .manifest_path = "/proc/absent.coral-workspace", .roots = &.{h.root}, .policy_digest = key(1) });
    defer base_input.deinit();
    try expectError(error.UnsupportedBirthTime, fs.capture(a, &base_input));
}

// Test-only encoder for the old, weaker domain and identity schema. Keeping it
// independent of the v2 hash makes the migration regression explicit on disk.
const LegacyV1 = struct {
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    fn number(self: *LegacyV1, n: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, n, .little);
        self.hash.update(&bytes);
    }
    fn field(self: *LegacyV1, bytes: []const u8) void {
        self.number(bytes.len);
        self.hash.update(bytes);
    }
    fn directory(self: *LegacyV1, dir: trust.Directory) void {
        self.field(dir.lexical);
        self.field(dir.canonical);
        self.number(dir.dev_major);
        self.number(dir.dev_minor);
        self.number(dir.inode);
    }
    fn fingerprint(identity: *const trust.Identity) trust.Fingerprint {
        var old: LegacyV1 = .{};
        old.field("coral.exact-workspace-trust.v1");
        old.number(if (identity.manifest_base != null) 1 else 0);
        if (identity.manifest_base) |base| old.directory(base);
        old.number(identity.roots.len);
        for (identity.roots) |root| old.directory(root);
        old.field(&identity.policy_digest);
        return old.hash.finalResult();
    }
};

test "persisted v1 inode-only approval cannot restore or approve a v2 scope" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    var identity = try fs.capture(a, &input);
    defer identity.deinit();
    const weak = LegacyV1.fingerprint(&identity);
    try expect(!trust.same(weak, identity.fingerprint));
    var records: trust.Records = .{};
    try records.approve(weak);
    const bytes = try records.encode(a);
    defer a.free(bytes);
    try h.overwrite(bytes);
    try equal(.restricted, (try fs.load(a, &h.home, &input)).state);
    try equal(.restricted, (try fs.revalidate(a, &h.home, &input, weak)).state);
    try expectError(error.ScopeChanged, fs.approve(a, &h.home, &input, weak, .user_approved));
    _ = try fs.approve(a, &h.home, &input, identity.fingerprint, .user_approved);
    try equal(.trusted, (try fs.load(a, &h.home, &input)).state);
}

fn exerciseBirthTime(home: *const fs.StateHome, root: [:0]const u8) !void {
    var input = try trust.Inputs.init(a, .{ .roots = &.{root}, .policy_digest = key(1) });
    defer input.deinit();
    var before = try fs.capture(a, &input);
    defer before.deinit();
    _ = try fs.approve(a, home, &input, before.fingerprint, .user_approved);

    // Directory entry changes and chmod change mtime/ctime, not incarnation.
    // Do not hold any root fd across rmdir below: this must permit inode reuse.
    const content = try std.fmt.allocPrintSentinel(a, "{s}/content", .{root}, 0);
    defer a.free(content);
    const fd = std.c.open(content, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try expect(fd >= 0);
    {
        defer _ = std.c.close(fd);
        defer _ = std.c.unlink(content);
        try equal(@as(isize, 6), std.c.write(fd, "edited", 6));
        var edited = try fs.capture(a, &input);
        defer edited.deinit();
        try equal(before.roots[0].birth_time, edited.roots[0].birth_time);
        try expect(trust.same(before.fingerprint, edited.fingerprint));
        try equal(.trusted, (try fs.revalidate(a, home, &input, before.fingerprint)).state);
    }
    try chmod(root, 0o755);
    try equal(.trusted, (try fs.revalidate(a, home, &input, before.fingerprint)).state);
    try chmod(root, 0o700);

    // Unlike the rename-to-retired test, actually free the inode before mkdir.
    // Whether the host recycles that inode is nondeterministic; the synthetic
    // same-inode test above deterministically covers both timestamp components.
    for (0..8) |_| {
        try equal(@as(c_int, 0), std.c.rmdir(root));
        try equal(@as(c_int, 0), std.c.mkdir(root, 0o700));
        var replacement = try fs.capture(a, &input);
        defer replacement.deinit();
        try expect(!std.meta.eql(before.roots[0].birth_time, replacement.roots[0].birth_time));
        try expect(!trust.same(before.fingerprint, replacement.fingerprint));
        try equal(.restricted, (try fs.load(a, home, &input)).state);
        try equal(.restricted, (try fs.revalidate(a, home, &input, before.fingerprint)).state);
        try expectError(error.ScopeChanged, fs.approve(a, home, &input, before.fingerprint, .user_approved));
    }
}

test "native root birth time survives content edits but not actual delete and recreate" {
    var h = try Home.init();
    defer h.deinit();
    // /tmp is ext4 on the development host; do not assume an inode cannot recycle.
    try exerciseBirthTime(&h.home, h.root);
}

test "tmpfs root supports stable birth time and delete-recreate invalidation" {
    var h = try Home.init();
    defer h.deinit();
    const root = try a.dupeSentinel(u8, "/dev/shm/coral-trust-btime-XXXXXX", 0);
    defer a.free(root);
    if (mkdtemp(root) == null) return error.TempDirectory;
    defer std.debug.assert(std.c.rmdir(root) == 0);
    try exerciseBirthTime(&h.home, root);
}

test "exact ordered roots, no recursive grants, and dev/inode replacement invalidation" {
    var h = try Home.init();
    defer h.deinit();
    try h.fixture.mkdir("project/child");
    const child = try h.fixture.path("project/child");
    defer a.free(child);
    var input = try h.inputs(1);
    defer input.deinit();
    const old = try fs.load(a, &h.home, &input);
    _ = try fs.approve(a, &h.home, &input, old.fingerprint, .user_approved);
    var nested = try trust.Inputs.init(a, .{ .roots = &.{child}, .policy_digest = key(1) });
    defer nested.deinit();
    try equal(.restricted, (try fs.load(a, &h.home, &nested)).state);
    var combined = try trust.Inputs.init(a, .{ .roots = &.{ h.root, child }, .policy_digest = key(1) });
    defer combined.deinit();
    const combined_key = (try fs.load(a, &h.home, &combined)).fingerprint;
    _ = try fs.approve(a, &h.home, &combined, combined_key, .user_approved);
    var reverse = try trust.Inputs.init(a, .{ .roots = &.{ child, h.root }, .policy_digest = key(1) });
    defer reverse.deinit();
    try equal(.restricted, (try fs.load(a, &h.home, &reverse)).state);

    // Keep the old inode alive, avoiding immediate inode reuse in the fixture.
    try h.fixture.mkdir("retired");
    const retired = try h.fixture.path("retired");
    defer a.free(retired);
    try equal(@as(c_int, 0), std.c.rmdir(retired));
    try equal(@as(c_int, 0), std.c.rename(h.root, retired));
    try equal(@as(c_int, 0), std.c.mkdir(h.root, 0o700));
    // Move the tracked child back so fixture cleanup keeps its original paths.
    const retired_child = try h.fixture.path("retired/child");
    defer a.free(retired_child);
    try equal(@as(c_int, 0), std.c.rename(retired_child, child));
    const replacement = try fs.load(a, &h.home, &input);
    try equal(.restricted, replacement.state);
    try expect(!trust.same(old.fingerprint, replacement.fingerprint));
    try expectError(error.ScopeChanged, fs.approve(a, &h.home, &input, old.fingerprint, .user_approved));
    try fs.revoke(a, &h.home, old.fingerprint);
}

test "manifest lexical parent and physical dot-dot semantics, symlink root retarget" {
    var h = try Home.init();
    defer h.deinit();
    try h.fixture.mkdir("project/child");
    try h.fixture.mkdir("elsewhere");
    try h.fixture.mkdir("elsewhere/deep");
    try h.fixture.write("elsewhere/source", "manifest contents are not trust");
    const source = try h.fixture.path("elsewhere/source");
    defer a.free(source);
    try h.fixture.symlink(source, "project/manifest");
    const manifest = try h.fixture.path("project/manifest");
    defer a.free(manifest);
    var inputs = try trust.Inputs.init(a, .{ .manifest_path = manifest, .roots = &.{"child"}, .policy_digest = key(1) });
    defer inputs.deinit();
    var captured = try fs.capture(a, &inputs);
    defer captured.deinit();
    const child = try h.fixture.path("project/child");
    defer a.free(child);
    try std.testing.expectEqualStrings(child, captured.roots[0].canonical);
    try std.testing.expectEqualStrings(h.root, captured.manifest_base.?.canonical);

    const deep = try h.fixture.path("elsewhere/deep");
    defer a.free(deep);
    try h.fixture.symlink(deep, "project/link");
    var physical = try trust.Inputs.init(a, .{ .manifest_path = manifest, .roots = &.{"link/.."}, .policy_digest = key(1) });
    defer physical.deinit();
    var resolved = try fs.capture(a, &physical);
    defer resolved.deinit();
    const elsewhere = try h.fixture.path("elsewhere");
    defer a.free(elsewhere);
    try std.testing.expectEqualStrings(elsewhere, resolved.roots[0].canonical);
    const link = try h.fixture.path("project/link");
    defer a.free(link);
    var alias = try trust.Inputs.init(a, .{ .roots = &.{link}, .policy_digest = key(1) });
    defer alias.deinit();
    const first = try fs.load(a, &h.home, &alias);
    _ = try fs.approve(a, &h.home, &alias, first.fingerprint, .user_approved);
    try equal(@as(c_int, 0), std.c.unlink(link));
    try equal(@as(c_int, 0), std.c.symlink(child, link));
    try equal(.restricted, (try fs.load(a, &h.home, &alias)).state);
}

test "unsafe store symlink, FIFO, directory, hardlink, modes and corruption fail closed" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    const initial = try fs.load(a, &h.home, &input);
    _ = try fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved);
    for ([_]std.c.mode_t{ 0o644, 0o660, 0o400, 0o1600 }) |mode| {
        try chmod(h.store, mode);
        try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
        try expectError(error.UnsafeFile, fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved));
        try chmod(h.store, 0o600);
    }
    try h.overwrite("{\"version\":1,\"trusted\":true}");
    try expectError(error.CorruptStore, fs.load(a, &h.home, &input));
    try expectError(error.CorruptStore, fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved));
    try expectError(error.CorruptStore, fs.revoke(a, &h.home, initial.fingerprint));
    try h.fixture.write("outside", "untouched");
    const outside = try h.fixture.path("outside");
    defer a.free(outside);
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.symlink(outside, h.store));
    try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), mkfifo(h.store, 0o600));
    try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
    try expectError(error.UnsafeFile, fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved));
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.mkdir(h.store, 0o700));
    try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
    try equal(@as(c_int, 0), std.c.rmdir(h.store));
    try equal(@as(c_int, 0), std.c.link(outside, h.store));
    try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
}

test "owner private state directories, ancestor symlinks, and project-local state reject" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    for ([_][]const u8{ "state", "state/coral", "state/coral/trust" }) |name| {
        const path = try h.fixture.path(name);
        defer a.free(path);
        try chmod(path, 0o777);
        try expectError(error.UnsafeDirectory, fs.load(a, &h.home, &input));
        try chmod(path, 0o700);
    }
    const state = try h.fixture.path("state");
    defer a.free(state);
    try h.fixture.symlink(state, "alias");
    const alias = try h.fixture.path("alias");
    defer a.free(alias);
    var unsafe = try fs.StateHome.init(a, alias);
    defer unsafe.deinit();
    try expectError(error.UnsafeDirectory, fs.load(a, &unsafe, &input));
    const through = try h.fixture.path("alias/coral");
    defer a.free(through);
    var ancestor = try fs.StateHome.init(a, through);
    defer ancestor.deinit();
    try expectError(error.UnsafeDirectory, fs.load(a, &ancestor, &input));
    var local = try fs.StateHome.init(a, h.root);
    defer local.deinit();
    try expectError(error.StateInsideWorkspace, fs.load(a, &local, &input));
    var store_as_root = try trust.Inputs.init(a, .{ .roots = &.{h.dir}, .policy_digest = key(1) });
    defer store_as_root.deinit();
    try expectError(error.StateInsideWorkspace, fs.load(a, &h.home, &store_as_root));
}

test "nonblocking lock contention, merge after retry, revoke cannot clobber another key" {
    var h = try Home.init();
    defer h.deinit();
    var first = try h.inputs(1);
    defer first.deinit();
    var second = try h.inputs(2);
    defer second.deinit();
    const one = try fs.load(a, &h.home, &first);
    const two = try fs.load(a, &h.home, &second);
    const fd = std.c.open(h.dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB));
    try expectError(error.Busy, fs.load(a, &h.home, &first));
    try expectError(error.Busy, fs.approve(a, &h.home, &first, one.fingerprint, .user_approved));
    try expectError(error.Busy, fs.revoke(a, &h.home, one.fingerprint));
    try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.UN));
    _ = try fs.approve(a, &h.home, &first, one.fingerprint, .user_approved);
    _ = try fs.approve(a, &h.home, &second, two.fingerprint, .user_approved);
    try fs.revoke(a, &h.home, one.fingerprint);
    try equal(.restricted, (try fs.load(a, &h.home, &first)).state);
    try equal(.trusted, (try fs.load(a, &h.home, &second)).state);
}

fn childApprove(home: *const fs.StateHome, root: []const u8, n: u32) !void {
    const allocator = std.heap.c_allocator;
    var input = try trust.Inputs.init(allocator, .{ .roots = &.{root}, .policy_digest = key(n) });
    defer input.deinit();
    var identity = try fs.capture(allocator, &input);
    defer identity.deinit();
    for (0..1000) |_| {
        _ = fs.approve(allocator, home, &input, identity.fingerprint, .user_approved) catch |err| {
            if (err != error.Busy) return err;
            _ = usleep(1000);
            continue;
        };
        return;
    }
    return error.RetryExhausted;
}
test "independent simultaneous writer processes re-read and merge without lost approvals" {
    var h = try Home.init();
    defer h.deinit();
    var pids: [4]std.c.pid_t = undefined;
    var count: usize = 0;
    var reaped: usize = 0;
    defer {
        for (pids[reaped..count]) |pid| {
            var status: c_int = 0;
            while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(@as(c_int, -1)) == .INTR) {}
        }
    }
    for (0..pids.len) |n| {
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(10);
            childApprove(&h.home, h.root, @intCast(n)) catch std.c._exit(1);
            std.c._exit(0);
        }
        pids[count] = pid;
        count += 1;
    }
    for (pids) |pid| {
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
        }
        reaped += 1;
        try equal(@as(c_int, 0), status);
    }
    for (0..pids.len) |n| {
        var input = try h.inputs(@intCast(n));
        defer input.deinit();
        try equal(.trusted, (try fs.load(a, &h.home, &input)).state);
    }
}

test "approval failures stay trusted, uncertain commit quarantines future loads" {
    for ([_]fs.Fault{ .during_write, .before_rename, .after_rename, .after_marker_remove }) |fault| {
        var h = try Home.init();
        defer h.deinit();
        var input = try h.inputs(1);
        defer input.deinit();
        const initial = try fs.load(a, &h.home, &input);
        var scope = routing.Scope.init();
        var policy = trust.Policy.init(scope.capture().?);
        const ticket = try policy.begin(scope.capture().?);
        const err = if (fault == .during_write or fault == .before_rename) error.InjectedFailure else error.DurabilityUncertain;
        try expectError(err, fs.approveWithHooks(a, &h.home, &input, initial.fingerprint, .user_approved, .{ .fault = fault }));
        // Workspace trust no longer depends on approval persistence: the ticket
        // completes and permits keep issuing even after a failed store write.
        try expect(policy.complete(ticket));
        _ = try policy.issue(.extensions);
        if (err == error.DurabilityUncertain) {
            try expectError(error.DurabilityUncertain, fs.load(a, &h.home, &input));
            try expectError(error.DurabilityUncertain, fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved));
        } else {
            try equal(.restricted, (try fs.load(a, &h.home, &input)).state);
            _ = try fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved);
        }
    }
}

test "failed persistent revocation surfaces errors without restricting the workspace" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    const initial = try fs.load(a, &h.home, &input);
    const approved = try fs.approve(a, &h.home, &input, initial.fingerprint, .user_approved);
    try equal(.trusted, approved.state);
    var scope = routing.Scope.init();
    var policy = trust.Policy.init(scope.capture().?);
    const permit = try policy.issue(.debug);
    const ticket = try policy.begin(scope.capture().?);
    try expect(!policy.validate(permit, scope.capture().?, .debug)); // begin retires stale permits
    try expectError(error.InjectedFailure, fs.revokeWithHooks(a, &h.home, initial.fingerprint, .{ .fault = .before_rename }));
    try expect(policy.complete(ticket));
    // Store failures never restrict: a new permit issues and validates, and a
    // background reload cannot change that either.
    const fresh = try policy.issue(.debug);
    try expect(policy.validate(fresh, scope.capture().?, .debug));
    const reloaded = try fs.load(a, &h.home, &input);
    try equal(.trusted, reloaded.state);
    const reload = try policy.begin(scope.capture().?);
    try expect(policy.complete(reload));
    _ = try policy.issue(.debug);
    try fs.revoke(a, &h.home, initial.fingerprint);
    try equal(.restricted, (try fs.load(a, &h.home, &input)).state);
}

test "missing store is restricted, approval provisions private directories, oversized file rejects" {
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.rmdir(h.dir));
    const coral = try h.fixture.path("state/coral");
    defer a.free(coral);
    try equal(@as(c_int, 0), std.c.rmdir(coral));
    const missing = try fs.load(a, &h.home, &input);
    try equal(.restricted, missing.state);
    try fs.revoke(a, &h.home, missing.fingerprint);
    _ = try fs.approve(a, &h.home, &input, missing.fingerprint, .user_approved);
    try equal(.trusted, (try fs.load(a, &h.home, &input)).state);
    const fd = std.c.open(h.store, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.ftruncate(fd, trust.limits.store_bytes + 1));
    try expectError(error.TooLarge, fs.load(a, &h.home, &input));
    try expectError(error.TooLarge, fs.approve(a, &h.home, &input, missing.fingerprint, .user_approved));
}

test "unavailable and FIFO roots never produce approvable identities" {
    var h = try Home.init();
    defer h.deinit();
    const missing = try h.fixture.path("absent");
    defer a.free(missing);
    var input = try trust.Inputs.init(a, .{ .roots = &.{missing}, .policy_digest = key(1) });
    defer input.deinit();
    try expectError(error.UnavailableRoot, fs.capture(a, &input));
    try h.fixture.fifo("fifo-root");
    const fifo = try h.fixture.path("fifo-root");
    defer a.free(fifo);
    var pipe_input = try trust.Inputs.init(a, .{ .roots = &.{fifo}, .policy_digest = key(1) });
    defer pipe_input.deinit();
    try expectError(error.UnsafeDirectory, fs.capture(a, &pipe_input));
}

test "foreign owner store and trust directory rejected when chown is available" {
    if (std.c.geteuid() != 0) return error.SkipZigTest;
    var h = try Home.init();
    defer h.deinit();
    var input = try h.inputs(1);
    defer input.deinit();
    for ([_][:0]const u8{ h.store, h.dir }) |path| {
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        try equal(@as(c_int, 0), std.c.fchown(fd, 1, 0));
        defer _ = std.c.fchown(fd, 0, 0);
        if (std.mem.eql(u8, path, h.store)) {
            try expectError(error.UnsafeFile, fs.load(a, &h.home, &input));
        } else {
            try expectError(error.UnsafeDirectory, fs.load(a, &h.home, &input));
        }
    }
}

fn allocationCase(allocator: std.mem.Allocator, root: []const u8, state: []const u8) !void {
    var home = try fs.StateHome.init(allocator, state);
    defer home.deinit();
    var inputs = try trust.Inputs.init(allocator, .{ .roots = &.{root}, .policy_digest = key(7) });
    defer inputs.deinit();
    var identity = try fs.capture(allocator, &inputs);
    defer identity.deinit();
    const before = try fs.load(allocator, &home, &inputs);
    try equal(.restricted, before.state);
    defer fs.revoke(a, &home, identity.fingerprint) catch unreachable;
    _ = try fs.approve(allocator, &home, &inputs, identity.fingerprint, .user_approved);
    const after = try fs.revalidate(allocator, &home, &inputs, identity.fingerprint);
    try equal(.trusted, after.state);
    try fs.revoke(allocator, &home, identity.fingerprint);
}
test "all allocation failures release owned input, capture, store buffers and locks" {
    var h = try Home.init();
    defer h.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ h.root, h.home.path });
}
