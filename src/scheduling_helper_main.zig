//! Privileged writer for scheduling profiles, run through pkexec.
//!
//! apply takes a profile id only: the command line comes from a root-owned
//! profile file, so any active user may choose a profile without a password.
//!
//! profiles save reads a whole profile list on stdin and makes it the
//! administrator's file in /etc; profiles reset removes that file, so the
//! profiles the package ships are used again. Both change what every user may
//! run as root, so their polkit action asks for an administrator password.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const p = @import("services/sched_profiles.zig");
const store = @import("services/sched_profiles_store.zig");
const a = std.heap.c_allocator;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-scheduling-helper " ++ @import("version.zig").string ++ "\n");
        return;
    }
    const usage = "usage: pearl-scheduling-helper apply PROFILE\n       pearl-scheduling-helper profiles save < FILE\n       pearl-scheduling-helper profiles reset";
    if (args.len != 3) fail(usage, .{});
    const edit = std.mem.eql(u8, args[1], "profiles");
    if (edit and !std.mem.eql(u8, args[2], "save") and !std.mem.eql(u8, args[2], "reset")) fail(usage, .{});
    if (!edit and (!std.mem.eql(u8, args[1], "apply") or !p.validId(args[2]))) fail(usage, .{});
    if (std.os.linux.getuid() != 0) fail("administrator privileges are required", .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    if (edit) return if (std.mem.eql(u8, args[2], "save")) save(alloc) else reset(alloc);

    const loaded = (store.load(alloc) catch |err| fail("cannot read scheduling profiles: {s}", .{@errorName(err)})) orelse fail("no scheduling profiles are installed", .{});
    const index = loaded.config.find(args[2]) orelse fail("unknown scheduling profile: {s}", .{args[2]});
    var profile = loaded.config.profiles[index];
    // The unit runs the path, so a binary installed later elsewhere on its
    // PATH cannot replace the chosen one.
    if (profile.sched) |sched| profile.sched = (store.resolve(alloc, sched) catch null) orelse fail("scheduler {s} is not installed", .{sched});

    write(p.env_path, "/etc/default", try p.render(alloc, profile)) catch |err| fail("cannot write {s}: {s}", .{ p.env_path, @errorName(err) });
    // Pearl owns scheduler selection: runtime overrides would otherwise
    // replace the selected profile.
    _ = run(&.{ "/usr/bin/systemctl", "unset-environment", "SCX_SCHEDULER_OVERRIDE", "SCX_FLAGS_OVERRIDE" });
    // Pearl no longer uses scx_loader, but older setups may still run it and
    // fight scx.service. Transitional; drop this in a future release.
    _ = run(&.{ "/usr/bin/systemctl", "stop", "scx_loader.service" });
    _ = quiet(&.{ "/usr/bin/systemctl", "reset-failed", "scx.service" });
    if (profile.stop) {
        if (!run(&.{ "/usr/bin/systemctl", "disable", "--now", "scx.service" })) fail("cannot stop scx.service", .{});
        return;
    }
    if (!run(&.{ "/usr/bin/systemctl", "enable", "scx.service" })) fail("cannot enable scx.service", .{});
    if (!run(&.{ "/usr/bin/systemctl", "restart", "scx.service" })) fail("scx.service failed to start {s}", .{profile.sched.?});
}

/// Make the profiles on stdin the administrator's file. They get the checks
/// of any profile file, and the shipped Default, which a failing scheduler
/// falls back to.
fn save(alloc: std.mem.Allocator) void {
    var bytes: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n < 0) fail("cannot read the profiles", .{});
        if (n == 0) break;
        if (bytes.items.len + @as(usize, @intCast(n)) > p.max_bytes) fail("the profiles are too large", .{});
        bytes.appendSlice(alloc, chunk[0..@intCast(n)]) catch fail("out of memory", .{});
    }
    const config = p.parse(alloc, bytes.items) catch |err| fail("invalid profiles: {s}", .{@errorName(err)});
    const shipped = (store.loadShipped(alloc) catch null) orelse p.Config{ .profiles = &.{p.builtin_default} };
    const locked = p.lockDefault(alloc, config, shipped) catch fail("out of memory", .{});
    const text = p.serialize(alloc, locked) catch fail("out of memory", .{});
    const path = (store.paths(alloc) catch |err| fail("cannot find the profile file: {s}", .{@errorName(err)}))[0];
    write(path, std.fs.path.dirname(path).?, text) catch |err| fail("cannot write {s}: {s}", .{ path, @errorName(err) });
}

/// Remove the administrator's file, so the shipped profiles are used again.
fn reset(alloc: std.mem.Allocator) void {
    _ = (store.loadShipped(alloc) catch null) orelse fail("no default scheduling profiles are installed", .{});
    const path = (store.paths(alloc) catch |err| fail("cannot find the profile file: {s}", .{@errorName(err)}))[0];
    switch (std.posix.errno(std.c.unlink(path))) {
        .SUCCESS, .NOENT => {},
        else => |err| fail("cannot remove {s}: {s}", .{ path, @tagName(err) }),
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("pearl-scheduling-helper: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// Replace path atomically with a root-owned file anyone may read.
fn write(path: [:0]const u8, dir: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrintSentinel(a, "{s}.XXXXXX", .{path}, 0);
    defer a.free(temp);
    const parent = try a.dupeZ(u8, dir);
    defer a.free(parent);
    if (glib.mkdirWithParents(parent, 0o755) != 0) return error.CreateDirectoryFailed;
    const fd = glib.mkstempFull(temp, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o644);
    if (fd < 0) return error.SaveFailed;
    defer _ = std.c.close(fd);
    errdefer _ = std.c.unlink(temp);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.SaveFailed;
        offset += @intCast(n);
    }
    if (std.c.fchmod(fd, 0o644) != 0 or std.c.fsync(fd) != 0) return error.SaveFailed;
    if (std.c.rename(temp, path) != 0) return error.SaveFailed;
}

fn run(argv: []const [*:0]const u8) bool {
    return spawn(argv, .{ .stdout_silence = true });
}

/// For steps whose failure is expected and harmless, such as resetting a unit
/// that never ran.
fn quiet(argv: []const [*:0]const u8) bool {
    return spawn(argv, .{ .stdout_silence = true, .stderr_silence = true });
}

fn spawn(argv: []const [*:0]const u8, flags: gio.SubprocessFlags) bool {
    var list: [8:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, i| list[i] = arg;
    var err: ?*glib.Error = null;
    const process = gio.Subprocess.newv(@ptrCast(&list), flags, &err) orelse {
        if (err) |e| e.free();
        return false;
    };
    defer process.unref();
    if (process.wait(null, &err) == 0) {
        if (err) |e| e.free();
        return false;
    }
    return process.getSuccessful() != 0;
}
