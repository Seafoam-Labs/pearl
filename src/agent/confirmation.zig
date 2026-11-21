//! Thread-safe confirmation channel between the inference worker and the GTK
//! main thread. The worker polls here (not the main loop) while the user
//! reviews an exact action preview. Approvals are single-use and expire.
const std = @import("std");
const glib = @import("glib2");

pub const Kind = enum { create_file, delete_file, delete_file_permanent, open_application };

pub const Preview = struct {
    kind: Kind,
    target: []const u8,
    content: []const u8 = "",
    bytes: usize = 0,
    application_id: []const u8 = "",
};

pub const Decision = enum(u8) { pending = 0, approved = 1, denied = 2, expired = 3, cancelled = 4, failed = 5 };

pub const timeout_us: i64 = 120 * std.time.us_per_s;
const poll_interval_us: c_uint = 50000;

pub const Channel = struct {
    state: std.atomic.Value(u8) = .init(0),
    has_preview: std.atomic.Value(bool) = .init(false),
    preview: Preview = undefined,
    error_code: []const u8 = "",
    /// Called from the worker to schedule a UI refresh on the main thread.
    notify: ?*const fn (*anyopaque) void = null,
    context: *anyopaque = undefined,

    /// Worker side: present a preview and block until the user responds.
    pub fn request(self: *Channel, preview: Preview) Decision {
        self.preview = preview;
        self.error_code = "";
        self.state.store(@backingInt(Decision.pending), .release);
        self.has_preview.store(true, .release);
        if (self.notify) |n| n(self.context);
        const deadline = glib.getMonotonicTime() + timeout_us;
        while (true) {
            const raw = self.state.load(.acquire);
            if (raw != @backingInt(Decision.pending)) {
                self.has_preview.store(false, .release);
                return @fromBackingInt(@intCast(raw));
            }
            if (glib.getMonotonicTime() >= deadline) {
                self.state.store(@backingInt(Decision.expired), .release);
                self.has_preview.store(false, .release);
                return .expired;
            }
            glib.usleep(poll_interval_us);
        }
    }

    /// Main-thread side: respond to the pending preview.
    pub fn respond(self: *Channel, decision: Decision, error_code: []const u8) void {
        self.error_code = error_code;
        self.state.store(@backingInt(decision), .release);
    }

    /// Main-thread side: read the pending preview (null if none).
    pub fn pending(self: *Channel) ?Preview {
        if (!self.has_preview.load(.acquire)) return null;
        return self.preview;
    }

    /// Invalidate any pending request (cancel/clear/shutdown/config change).
    pub fn cancel(self: *Channel) void {
        if (self.has_preview.load(.acquire)) {
            self.state.store(@backingInt(Decision.cancelled), .release);
        }
    }
};

test "confirmation channel round-trips approval" {
    var channel: Channel = .{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Channel) void {
            glib.usleep(10000);
            ch.respond(.approved, "");
        }
    }.run, .{&channel});
    const decision = channel.request(.{ .kind = .delete_file, .target = "/tmp/test.txt", .bytes = 42 });
    thread.join();
    try std.testing.expectEqual(Decision.approved, decision);
    try std.testing.expect(channel.pending() == null);
}

test "confirmation channel cancel unblocks worker" {
    var channel: Channel = .{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Channel) void {
            glib.usleep(10000);
            ch.cancel();
        }
    }.run, .{&channel});
    const decision = channel.request(.{ .kind = .create_file, .target = "/tmp/new.txt", .content = "hi", .bytes = 2 });
    thread.join();
    try std.testing.expectEqual(Decision.cancelled, decision);
}
