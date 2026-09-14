//! Unprivileged authentication subprocess. Linux-PAM owns privileged helpers.
const std = @import("std");
const pam = @import("pam");
const wire = @import("conversation.zig");
var exchanges: usize = 0;
fn conversation(count: c_int, messages: [*c][*c]const pam.pam_message, responses: [*c][*c]pam.pam_response, _: ?*anyopaque) callconv(.c) c_int {
    if (count <= 0 or count > 32 or exchanges + @as(usize, @intCast(count)) > 64) return pam.PAM_CONV_ERR;
    exchanges += @intCast(count);
    const output: [*c]pam.pam_response = @ptrCast(@alignCast(std.c.calloc(@intCast(count), @sizeOf(pam.pam_response)) orelse return pam.PAM_BUF_ERR));
    var ok = false;
    defer if (!ok) {
        for (0..@intCast(count)) |i| if (output[i].resp != null) {
            std.crypto.secureZero(u8, std.mem.span(output[i].resp));
            std.c.free(output[i].resp);
        };
        std.c.free(output);
    };
    for (0..@intCast(count)) |i| {
        if (messages[i] == null or messages[i].*.msg == null) return pam.PAM_CONV_ERR;
        const msg = messages[i].*;
        if (msg.msg_style < 1 or msg.msg_style > 4) return pam.PAM_CONV_ERR;
        var packet: wire.Packet = .{ .kind = @intCast(msg.msg_style) };
        defer packet.wipe();
        if (!packet.set(std.mem.span(msg.msg))) return pam.PAM_CONV_ERR;
        if (!wire.write(1, &packet)) return pam.PAM_CONV_ERR;
        if (msg.msg_style == pam.PAM_PROMPT_ECHO_OFF or msg.msg_style == pam.PAM_PROMPT_ECHO_ON) {
            if (!wire.read(0, &packet) or packet.kind != 101) return pam.PAM_CONV_ERR;
            const answer: [*c]u8 = @ptrCast(std.c.malloc(packet.length + 1) orelse return pam.PAM_BUF_ERR);
            @memcpy(answer[0 .. packet.length + 1], packet.bytes[0 .. packet.length + 1]);
            output[i].resp = answer;
        }
    }
    responses.* = output;
    ok = true;
    return pam.PAM_SUCCESS;
}
pub fn main() void {
    // Never accept a username, service or PAM directory from a production caller.
    const user = pam.getpwuid(pam.getuid()) orelse return;
    var conv: pam.pam_conv = .{ .conv = conversation, .appdata_ptr = null };
    var handle: ?*pam.pam_handle_t = null;
    var status: c_int = pam.PAM_SYSTEM_ERR;
    if (@import("build_options").test_hooks) {
        const dir = std.c.getenv("PEARL_TEST_PAM_DIR") orelse return;
        if (!std.mem.startsWith(u8, std.mem.span(dir), "/tmp/pearl-dev-")) return;
        status = pam.pam_start_confdir("pearl", user.*.pw_name, &conv, dir, &handle);
    } else status = pam.pam_start("pearl", user.*.pw_name, &conv, &handle);
    if (status == pam.PAM_SUCCESS) {
        status = pam.pam_authenticate(handle, pam.PAM_DISALLOW_NULL_AUTHTOK);
        if (status == pam.PAM_SUCCESS) status = pam.pam_acct_mgmt(handle, 0);
        _ = pam.pam_end(handle, status);
    }
    var result: wire.Packet = .{ .kind = 100, .value = @intCast(status) };
    _ = wire.write(1, &result);
}
