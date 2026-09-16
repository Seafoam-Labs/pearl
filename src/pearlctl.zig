const std = @import("std");
const glib = @import("glib2");
const wire = @import("aqueous/transport.zig");
const codec = @import("aqueous/codec.zig");
const protocol = @import("cli/protocol.zig");
const options = @import("cli/options.zig");
const startup = @import("core/startup.zig");
const a = std.heap.c_allocator;
const Client = struct {
    transport: wire.Transport = undefined,
    loop: *glib.MainLoop,
    request: protocol.Request,
    runtime: []const u8,
    display: [:0]u8,
    session: [32]u8 = undefined,
    phase: enum { aqueous, control } = .aqueous,
    deadline: c_uint = 0,
    status: u8 = 3,
    done: bool = false,
    fn stop(self: *Client, err: anyerror) void {
        if (self.done) return;
        self.done = true;
        const code = if (self.phase == .control and self.transport.sent > 0) "UnknownCompletion" else @errorName(err);
        const json = std.json.Stringify.valueAlloc(a, .{ .pearl = 1, .ok = false, .err = .{ .code = code } }, .{}) catch unreachable;
        defer a.free(json);
        const output = a.dupeZ(u8, json) catch unreachable;
        defer a.free(output);
        glib.print("%s\n", output.ptr);
        self.loop.quit();
    }
    fn event(context: *anyopaque, value: wire.Event) void {
        const self: *Client = @ptrCast(@alignCast(context));
        switch (value) {
            .sent => {},
            .failed => |err| self.stop(err),
            .connected => self.send() catch |err| self.stop(err),
            .frame => |bytes| self.receive(bytes) catch |err| self.stop(err),
        }
    }
    fn send(self: *Client) !void {
        if (self.phase == .aqueous) {
            try self.transport.send("{\"ipc\":1,\"id\":\"1\",\"op\":\"hello\",\"params\":{}}\n");
            return;
        }
        self.request.session = &self.session;
        self.request.display = self.display;
        const payload = try std.json.Stringify.valueAlloc(a, self.request, .{ .emit_null_optional_fields = false });
        defer a.free(payload);
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{payload});
        defer a.free(frame);
        try self.transport.send(frame);
    }
    fn receive(self: *Client, bytes: []const u8) !void {
        if (self.done) return;
        if (self.phase == .aqueous) {
            var decoded = try codec.decode(a, bytes, .{}, .hello);
            defer decoded.deinit();
            if (decoded.message != .response or !std.mem.eql(u8, decoded.message.response.id, "1")) return error.InvalidHello;
            @memcpy(&self.session, decoded.message.response.result.hello.session);
            const path = try protocol.endpoint(a, self.runtime, &self.session);
            defer a.free(path);
            self.phase = .control;
            self.transport.close();
            self.transport.sent = 0;
            self.transport.framer.limit = protocol.max_frame;
            try self.transport.open(path);
            _ = glib.Source.remove(self.deadline);
            self.deadline = glib.timeoutAdd(5000, timeout, self);
        } else {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
            defer parsed.deinit();
            const e = @import("aqueous/entities.zig");
            const v = parsed.value;
            if (try e.read(u32, a, try e.field(v, "pearl")) != 1 or !std.mem.eql(u8, try e.read([]const u8, a, try e.field(v, "id")), "1")) return error.InvalidReply;
            const ok = try e.read(bool, a, try e.field(v, "ok"));
            const text = try a.dupeZ(u8, bytes);
            defer a.free(text);
            glib.print("%s\n", text.ptr);
            self.status = if (ok) 0 else 4;
            self.done = true;
            self.loop.quit();
        }
    }
    fn timeout(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        self.deadline = 0;
        self.stop(error.Timeout);
        return 0;
    }
};
fn env(name: [*:0]const u8) []const u8 {
    return if (glib.getenv(name)) |v| std.mem.span(v) else "";
}
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    const alloc = init.arena.allocator();
    if (args.len > 1 and std.mem.eql(u8, args[1], "migrate")) {
        @import("config/migration_cli.zig").run(alloc, args[2..]) catch |err| {
            glib.printerr("Migration failed: %s\n", @errorName(err).ptr);
            std.process.exit(2);
        };
        return;
    }
    // Read explicit preference files locally; never send filesystem paths to the server.
    const normalized = alloc.dupe([]const u8, args[1..]) catch std.process.exit(2);
    if (normalized.len >= 2 and std.mem.eql(u8, normalized[0], "preferences") and std.mem.eql(u8, normalized[1], "apply")) {
        var i: usize = 2;
        while (i + 1 < normalized.len) : (i += 2) if (std.mem.eql(u8, normalized[i], "--file")) {
            const bytes = @import("config/migration_cli.zig").file(alloc, normalized[i + 1]) catch |err| {
                glib.printerr("Preference file: %s\n", @errorName(err).ptr);
                std.process.exit(2);
            };
            _ = @import("config/preferences.zig").parse(alloc, bytes) catch |err| {
                glib.printerr("Invalid preferences: %s\n", @errorName(err).ptr);
                std.process.exit(2);
            };
            normalized[i] = "--text";
            normalized[i + 1] = bytes;
        };
    }
    const parsed = options.parse(normalized) catch {
        glib.printerr("%s", options.usage);
        std.process.exit(2);
    };
    switch (parsed) {
        .help => {
            glib.print("%s", options.usage);
            return;
        },
        .version => {
            glib.print("pearlctl " ++ @import("version.zig").string ++ " (control v1, Zig 0.16.0)\n");
            return;
        },
        .request => {},
    }
    startup.validate(.session, .{ .desktop = env("XDG_CURRENT_DESKTOP"), .runtime = env("XDG_RUNTIME_DIR"), .display = env("WAYLAND_DISPLAY"), .endpoint = env("AQUEOUS_SOCKET") }) catch {
        glib.printerr("pearlctl requires a current Aqueous session environment.\n");
        std.process.exit(3);
    };
    const display = protocol.displayPath(a, env("XDG_RUNTIME_DIR"), env("WAYLAND_DISPLAY")) catch std.process.exit(3);
    var client: Client = .{ .loop = glib.MainLoop.new(null, 0), .request = parsed.request, .runtime = env("XDG_RUNTIME_DIR"), .display = display };
    if (client.request.op == .settings_show or client.request.op == .aqueous_show) {
        const token = if (env("XDG_ACTIVATION_TOKEN").len > 0) env("XDG_ACTIVATION_TOKEN") else env("DESKTOP_STARTUP_ID");
        if (token.len > 0 and token.len <= 4096) client.request.activation = token;
    }
    client.transport = wire.Transport.init(&client, Client.event);
    client.deadline = glib.timeoutAdd(5000, Client.timeout, &client);
    client.transport.open(std.mem.span(glib.getenv("AQUEOUS_SOCKET").?)) catch |err| client.stop(err);
    if (!client.done) client.loop.run();
    if (client.deadline != 0) _ = glib.Source.remove(client.deadline);
    client.transport.deinit();
    client.loop.unref();
    a.free(display);
    std.process.exit(client.status);
}
