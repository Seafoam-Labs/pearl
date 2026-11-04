//! Main-context-only lifetime of the worker descriptor watch.
const glib = @import("glib2");
const std = @import("std");

pub const Watch = struct {
    source: c_uint = 0,

    pub fn attach(self: *Watch, fd: c_int, callback: *const fn (*glib.IOChannel, glib.IOCondition, ?*anyopaque) callconv(.c) c_int, context: *anyopaque) void {
        std.debug.assert(self.source == 0);
        const channel = glib.IOChannel.unixNew(fd);
        defer channel.unref();
        self.source = glib.ioAddWatch(channel, .{ .in = true }, callback, context);
    }

    pub fn detach(self: *Watch) void {
        if (self.source != 0) _ = glib.Source.remove(self.source);
        self.source = 0;
    }
};
