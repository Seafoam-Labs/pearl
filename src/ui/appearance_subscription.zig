//! Verified committed appearance, without application-specific CSS or defaults.
//! Snapshots are borrowed only for the duration of the callback.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const Client = @import("../settings/client.zig").Client;
const Identity = @import("../settings/identity.zig").Identity;
const Snapshot = @import("../settings/appearance.zig").Snapshot;
const a = std.heap.c_allocator;

pub const Subscription = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, Snapshot) void,
    client: Client,
    identity: ?Identity = null,
    display: [:0]u8,
    retry: c_uint = 0,
    subscribed: bool = false,
    last_revision: ?u64 = null,

    fn native(context: *anyopaque) void {
        const self: *Subscription = @ptrCast(@alignCast(context));
        self.client.nativeChanged(self.identity.?.session);
    }
    fn event(context: *anyopaque, value: @import("../settings/client.zig").Event) void {
        const self: *Subscription = @ptrCast(@alignCast(context));
        switch (value) {
            .connected => |snapshot| if (snapshot) |s| {
                if (self.retry != 0) _ = glib.Source.remove(self.retry);
                self.retry = 0;
                if (self.last_revision != s.revision) {
                    self.last_revision = s.revision;
                    self.changed(self.context, s);
                }
                // Hello/ping alone do not subscribe. Appearance page entry is
                // read-only and enables the existing coalesced change events.
                if (!self.subscribed and self.client.capabilities.page_snapshots) {
                    self.client.request(.@"page.enter", .{ .page = "appearance" }) catch return;
                    self.subscribed = true;
                }
            },
            .reply => |reply| if (reply.op == .@"page.enter" and reply.error_code != null) {
                self.subscribed = false;
            },
            .failed => {
                self.subscribed = false;
                // A restarted backend may reuse a revision number.
                self.last_revision = null;
                if (self.retry == 0) self.retry = glib.timeoutAdd(3000, retryTick, self);
            },
            else => {},
        }
    }
    fn retryTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Subscription = @ptrCast(@alignCast(data.?));
        self.retry = 0;
        self.client.begin();
        return 0;
    }
    fn env(name: [:0]const u8) [:0]const u8 {
        return if (glib.getenv(name)) |v| std.mem.span(v) else "";
    }
    pub fn start(context: *anyopaque, changed: @FieldType(Subscription, "changed")) !*Subscription {
        const display = try @import("../cli/protocol.zig").displayPath(a, env("XDG_RUNTIME_DIR"), env("WAYLAND_DISPLAY"));
        errdefer a.free(display);
        const self = try a.create(Subscription);
        errdefer a.destroy(self);
        self.* = .{ .context = context, .changed = changed, .display = display, .client = .{ .context = self, .notify = event, .runtime = env("XDG_RUNTIME_DIR"), .display = display, .aqueous_path = env("AQUEOUS_SOCKET") } };
        self.client.init();
        errdefer self.client.deinit();
        self.identity = try Identity.init(gdk.Display.getDefault() orelse return error.NoDisplay, self, native);
        self.identity.?.start();
        self.client.begin();
        return self;
    }
    pub fn stop(self: *Subscription) void {
        if (self.retry != 0) _ = glib.Source.remove(self.retry);
        if (self.identity) |*identity| identity.deinit();
        self.client.deinit();
        a.free(self.display);
        a.destroy(self);
    }
};
