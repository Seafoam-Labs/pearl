//! Test-only adapter. No command/credential fixtures are included in production.
const std = @import("std");
const glib = @import("glib2");
const Client = @import("client.zig").Client;
const Probe = struct {
    client: Client = undefined,
    loop: *glib.MainLoop,
    cancelled: bool = false,
    remaining: usize = 0,
    status: u8 = 1,
    fn changed(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        std.log.info("event=greeter-state state={s}", .{@tagName(self.client.controller.state)});
        switch (self.client.controller.state) {
            .prompt => {
                if ((glib.getenv("PEARL_TEST_GREETER_CANCEL") != null and !self.cancelled) or (self.remaining > 0 and self.client.controller.needsInput())) {
                    self.cancelled = true;
                    self.client.cancel() catch {};
                    return;
                }
                const c = &self.client.controller;
                if (!c.needsInput()) {
                    // Simulate duplicate Enter while the client's passive ack is queued.
                    std.debug.assert(self.client.answer(c.prompt_generation, null) == error.NoInputQuestion);
                    return;
                }
                self.client.answer(c.prompt_generation, switch (c.kind) {
                    .visible => "fixture-user",
                    .secret => "fixture-secret",
                    .info, .@"error" => unreachable,
                }) catch self.loop.quit();
            },
            .authenticated => self.client.start(&.{"PEARL_SESSION_ID=wayland:fixture.desktop"}) catch self.loop.quit(),
            .handoff => {
                self.status = 0;
                self.loop.quit();
            },
            .failed => self.client.cancel() catch self.loop.quit(),
            .idle => {
                if (self.remaining > 0) {
                    self.remaining -= 1;
                    if (self.remaining > 0) {
                        self.client.begin("fixture-user") catch self.loop.quit();
                        return;
                    }
                }
                self.status = if (self.cancelled) 0 else 2;
                self.loop.quit();
            },
            .unavailable => self.loop.quit(),
            else => {},
        }
    }
};
pub fn run() !void {
    const path = glib.getenv("GREETD_SOCK") orelse return error.MissingSocket;
    var probe: Probe = .{ .loop = glib.MainLoop.new(null, 0) };
    if (glib.getenv("PEARL_TEST_GREETER_CYCLES")) |n| {
        probe.remaining = try std.fmt.parseInt(usize, std.mem.span(n), 10);
        if (probe.remaining > 1000) return error.CycleLimit;
    }
    probe.client = .{ .path = std.mem.span(path), .context = &probe, .changed = Probe.changed, .timeout_ms = 500 };
    probe.client.init();
    defer probe.client.deinit();
    defer probe.loop.unref();
    try probe.client.begin("fixture-user");
    probe.loop.run();
    if (probe.status != 0) return error.ProbeFailed;
}
