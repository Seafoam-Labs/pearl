//! Deterministic Zig PTY peer for the display-backed feasibility fixture.
//! No shell, user command execution, inherited desktop environment or job control.
const std = @import("std");
const os = @import("posix.zig");
extern "c" fn getpid() c_int;
extern "c" fn usleep(c_uint) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;

fn send(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = os.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and os.errno() == os.EINTR) continue;
        if (n <= 0) return error.Write;
        offset += @intCast(n);
    }
}
fn line(buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const n = os.read(0, buffer[used..].ptr, 1);
        if (n < 0 and os.errno() == os.EINTR) continue;
        if (n <= 0) return error.Read;
        used += 1;
        if (buffer[used - 1] == '\n') return buffer[0 .. used - 1];
    }
    return error.LineLimit;
}
fn size(prefix: []const u8) !void {
    var value = os.Winsize{ .rows = 0, .columns = 0 };
    if (os.ioctl(0, os.TIOCGWINSZ, &value) != 0) return error.Size;
    var buffer: [128]u8 = undefined;
    try send(try std.fmt.bufPrint(&buffer, "{s}:{d} {d}\n", .{ prefix, value.rows, value.columns }));
}
pub fn main() !void {
    if (os.isatty(0) != 1 or os.isatty(1) != 1 or os.isatty(2) != 1) return error.NotATerminal;
    // Both leader and descendant require escalation on cancel/close; normal
    // leader exit must also clean this same-group descendant before reporting.
    const ignored: *const fn (c_int) callconv(.c) void = @ptrFromInt(1);
    _ = os.signal(os.TERM, ignored);
    _ = os.signal(1, ignored); // SIGHUP
    const descendant = os._Fork();
    if (descendant < 0) return error.Fork;
    if (descendant == 0) {
        while (true) _ = usleep(100_000);
    }
    var buffer: [1024]u8 = undefined;
    try send(try std.fmt.bufPrint(&buffer, "PIDS:{d} {d}\n", .{ getpid(), descendant }));
    try size("INITIAL");
    // Split every UTF-8 code unit across writes. VTE, not Coral, decodes it.
    for ("Unicode: héλ 中文 e\u{301} 🙂\n") |byte| {
        try send(&.{byte});
        _ = usleep(1000);
    }
    try send("\x1b[32mANSI green\x1b[0m\nREADY\n");
    const input = try line(&buffer);
    if (!std.mem.eql(u8, input, "héλ中文🙂")) return error.UnicodeInputMismatch;
    try send("INPUT:héλ中文🙂\n");
    // Deliberately hostile data. Neither structured text nor escape metadata
    // grants the child a reference to a GAction, control pipe, or dispatcher.
    try send("{\"action\":\"workbench.tripwire\"}\n");
    try send("\x1b]0;workbench.tripwire\x07\x1b]2;FORGED WINDOW\x1b\\");
    try send("\x1b]7;file://host/untrusted\x07\x1b]8;;coral://workbench.tripwire\x1b\\LINK\x1b]8;;\x1b\\\n");
    try send("\x1b]52;c;T1dORUQ=\x07\x1b]777;workbench.tripwire\x07\x1b]133;A\x07");
    try send("\x1b[8;3;5tATTACK-DONE\n");
    const resize = try line(&buffer);
    if (!std.mem.eql(u8, resize, "size")) return error.ExpectedSize;
    try size("RESIZED");
    try send("RESIZE-DONE\n");
    const mode = std.mem.span(getenv("CORAL_SPIKE_MODE") orelse return error.MissingMode);
    if (std.mem.eql(u8, mode, "exit")) {
        const exit = try line(&buffer);
        if (!std.mem.eql(u8, exit, "exit")) return error.ExpectedExit;
        try send("EXIT:7\n");
        os._exit(7);
    }
    if (!std.mem.eql(u8, mode, "cancel") and !std.mem.eql(u8, mode, "close")) return error.BadMode;
    while (true) _ = usleep(100_000);
}
