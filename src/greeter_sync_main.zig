const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const sync = @import("greeter/appearance_sync.zig");
const db = @import("services/dbus_peer.zig");
const log = std.log.scoped(.greeter);

pub const std_options = @import("core/logging.zig").std_options;

const Ucred = extern struct { pid: u32, uid: u32, gid: u32 };
const action_id = "org.aqueous.Pearl.Greeter.Appearance";

/// Sequential system-bus caller driven by a private main loop. The service
/// mode needs logind and the polkit authority before it touches any file.
const Caller = struct {
    app: *gio.Application,
    loop: *glib.MainLoop,
    peer: db.Peer = undefined,
    result: ?*glib.Variant = null,
    err: ?[]const u8 = null,

    fn peerChanged(context: *anyopaque, _: bool) void {
        _ = context;
    }
    fn done(context: *anyopaque, _: u64, result: ?*glib.Variant, err: ?[]const u8) void {
        const self: *Caller = @ptrCast(@alignCast(context));
        self.result = result;
        self.err = err;
        self.loop.quit();
    }
    fn timeout(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Caller = @ptrCast(@alignCast(context.?));
        self.loop.quit();
        return 0;
    }
    fn spin(self: *Caller, ms: c_uint) void {
        const source = glib.timeoutAdd(ms, timeout, self);
        self.loop.run();
        _ = glib.Source.remove(source);
    }
    fn init(self: *Caller, app: *gio.Application, loop: *glib.MainLoop, name: [:0]const u8, root: [:0]const u8) void {
        self.* = .{ .app = app, .loop = loop };
        self.peer = .{ .app = app, .context = self, .changed = peerChanged, .name = name, .root = root, .managed = false };
        self.peer.start();
        var waited: c_uint = 0;
        while (self.peer.connection() == null and waited < 5000) : (waited += 100) self.spin(100);
    }
    fn call(self: *Caller, path: [:0]const u8, iface: [:0]const u8, method: [:0]const u8, params: ?*glib.Variant, signature: [:0]const u8) ?*glib.Variant {
        if (self.peer.connection() == null) return null;
        self.result = null;
        self.err = null;
        self.peer.call(1, path, iface, method, params, signature, 20000, done) catch return null;
        self.spin(25000);
        if (self.err != null) return null;
        return self.result;
    }
    fn deinit(self: *Caller) void {
        self.peer.stop();
    }
};

/// The caller's processes usually live outside any logind session scope, so
/// resolve the uid's display session the same way the shell's fallback does.
fn displaySession(caller: *Caller, uid: u32, buffer: *[128]u8) ?[:0]u8 {
    const user = caller.call("/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetUser", db.tuple(&.{glib.Variant.newUint32(uid)}), "(o)") orelse return null;
    defer user.unref();
    const user_path = user.getChildValue(0);
    defer user_path.unref();
    const display = caller.call(std.mem.span(user_path.getString(null)), "org.freedesktop.DBus.Properties", "Get", db.tuple(&.{ db.str("org.freedesktop.login1.User"), db.str("Display") }), "(v)") orelse return null;
    defer display.unref();
    const inner = display.getChildValue(0);
    defer inner.unref();
    const pair = inner.getVariant();
    defer pair.unref();
    const session_path = pair.getChildValue(1);
    defer session_path.unref();
    const id = caller.call(std.mem.span(session_path.getString(null)), "org.freedesktop.DBus.Properties", "Get", db.tuple(&.{ db.str("org.freedesktop.login1.Session"), db.str("Id") }), "(v)") orelse return null;
    defer id.unref();
    const id_inner = id.getChildValue(0);
    defer id_inner.unref();
    const value = id_inner.getVariant();
    defer value.unref();
    const text = std.mem.span(value.getString(null));
    if (text.len == 0 or text.len >= buffer.len) return null;
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return buffer[0..text.len :0];
}

/// Explicit-subject authorization: the Pearl shell registers its prompt agent
/// for the login session, so naming that session works even when neither the
/// client nor this service lives inside a session cgroup.
fn authorized(caller: *Caller, session: [:0]const u8) bool {
    const subject = db.tuple(&.{ db.str("unix-session"), db.array("{sv}", &.{db.entry("session-id", db.str(session))}) });
    const params = db.tuple(&.{ subject, db.str(action_id), db.array("{sv}", &.{}), glib.Variant.newUint32(1), db.str("") });
    const reply = caller.call("/org/freedesktop/PolicyKit1/Authority", "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization", params, "(bb)") orelse return false;
    defer reply.unref();
    const granted = reply.getChildValue(0);
    defer granted.unref();
    return granted.getBoolean() != 0;
}

fn say(text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = std.c.write(1, text.ptr + offset, text.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}

fn service() u8 {
    if (std.os.linux.getuid() != 0) return 1;
    var cred: Ucred = undefined;
    var len: u32 = @sizeOf(Ucred);
    const rc: isize = @bitCast(std.os.linux.getsockopt(0, 1, 17, @ptrCast(&cred), &len)); // SOL_SOCKET, SO_PEERCRED
    if (rc < 0 or len < @sizeOf(Ucred)) return 1;
    const app = gio.Application.new(null, .{ .non_unique = true });
    defer app.unref();
    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    var buffer: [128]u8 = undefined;
    var login: Caller = undefined;
    login.init(app, loop, "org.freedesktop.login1", "/org/freedesktop/login1");
    const session = displaySession(&login, cred.uid, &buffer);
    login.deinit();
    const resolved = session orelse {
        say("NoSession\n");
        return 1;
    };
    var polkit: Caller = undefined;
    polkit.init(app, loop, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority");
    const ok = authorized(&polkit, resolved);
    polkit.deinit();
    if (!ok) {
        say("denied\n");
        return 1;
    }
    const bytes = sync.read(0, sync.max_request) catch {
        say("ReadFailed\n");
        return 1;
    };
    defer std.heap.c_allocator.free(bytes);
    sync.apply("/etc/pearl", bytes) catch |err| {
        var line: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s}\n", .{@errorName(err)}) catch "ApplyFailed\n";
        say(text);
        return 1;
    };
    say("ok\n");
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter-sync " ++ @import("version.zig").string ++ "\n");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--service")) {
        std.process.exit(service());
    }
    var directory: []const u8 = "/etc/pearl";
    if (@import("build_options").test_hooks and args.len == 3 and std.mem.eql(u8, args[1], "--fixture")) {
        directory = args[2];
    } else if (args.len != 2 or !std.mem.eql(u8, args[1], "--apply") or std.os.linux.getuid() != 0) return error.AdministratorRequired;
    const bytes = try sync.read(0, sync.max_request);
    defer std.heap.c_allocator.free(bytes);
    sync.apply(directory, bytes) catch |err| {
        log.err("{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
