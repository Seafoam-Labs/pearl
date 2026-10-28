//! Privileged writer for scheduling profiles, run through pkexec. It accepts a
//! profile id only; the command line comes from the system profile file, so a
//! caller can choose among the administrator's profiles but never supply one.
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
    if (args.len != 3 or !std.mem.eql(u8, args[1], "apply") or !p.validId(args[2])) fail("usage: pearl-scheduling-helper apply PROFILE", .{});
    if (std.os.linux.getuid() != 0) fail("administrator privileges are required", .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const loaded = (store.load(alloc) catch |err| fail("cannot read scheduling profiles: {s}", .{@errorName(err)})) orelse fail("no scheduling profiles are installed", .{});
    const index = loaded.config.find(args[2]) orelse fail("unknown scheduling profile: {s}", .{args[2]});
    const profile = loaded.config.profiles[index];
    if (profile.sched) |sched| if (!installed(alloc, sched)) fail("scheduler {s} is not installed", .{sched});

    write(try p.render(alloc, profile)) catch |err| fail("cannot write {s}: {s}", .{ p.env_path, @errorName(err) });
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

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("pearl-scheduling-helper: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// The unit runs the scheduler by name, so it must be on systemd's PATH.
fn installed(alloc: std.mem.Allocator, sched: []const u8) bool {
    for ([_][]const u8{ "/usr/local/bin", "/usr/bin" }) |dir| {
        const path = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, sched }, 0) catch return false;
        if (std.c.access(path, std.c.X_OK) == 0) return true;
    }
    return false;
}

fn write(bytes: []const u8) !void {
    const temp = try a.dupeSentinel(u8, p.env_path ++ ".XXXXXX", 0);
    defer a.free(temp);
    if (glib.mkdirWithParents("/etc/default", 0o755) != 0) return error.CreateDirectoryFailed;
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
    if (std.c.rename(temp, p.env_path) != 0) return error.SaveFailed;
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
