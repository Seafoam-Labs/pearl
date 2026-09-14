//! Isolated PAM module; only the non-installed test locker uses this stack.
const std = @import("std");
const pam = @import("pam");
export fn pam_sm_authenticate(handle: ?*pam.pam_handle_t, _: c_int, argc: c_int, argv: [*c][*c]const u8) c_int {
    const mode = if (argc > 0) std.mem.span(argv[0]) else "normal";
    if (std.mem.eql(u8, mode, "crash")) std.process.exit(9);
    if (std.mem.eql(u8, mode, "hang")) {
        _ = pam.sleep(120);
        return pam.PAM_AUTH_ERR;
    }
    if (std.mem.eql(u8, mode, "malformed")) {
        // Same-size frame with an invalid length, emitted only by this test module.
        var frame: extern struct { kind: u32 = 100, value: u32 = 0, length: u32 = 1024, bytes: [1024]u8 = @splat(0) } = .{};
        const bytes = std.mem.asBytes(&frame);
        _ = std.c.write(1, bytes.ptr, bytes.len);
        return pam.PAM_AUTH_ERR;
    }
    var item: ?*const anyopaque = null;
    if (pam.pam_get_item(handle, pam.PAM_CONV, &item) != pam.PAM_SUCCESS or item == null) return pam.PAM_SYSTEM_ERR;
    const conv: *const pam.pam_conv = @ptrCast(@alignCast(item.?));
    var messages = [_]pam.pam_message{
        .{ .msg_style = pam.PAM_TEXT_INFO, .msg = "Private PAM conversation" },
        .{ .msg_style = pam.PAM_ERROR_MSG, .msg = "Test informational error" },
        .{ .msg_style = pam.PAM_PROMPT_ECHO_ON, .msg = "Fixture identity:" },
        .{ .msg_style = pam.PAM_PROMPT_ECHO_OFF, .msg = "Fixture password:" },
    };
    var pointers = [_][*c]const pam.pam_message{ &messages[0], &messages[1], &messages[2], &messages[3] };
    var responses: [*c]pam.pam_response = null;
    if (conv.conv.?(4, &pointers, &responses, conv.appdata_ptr) != pam.PAM_SUCCESS or responses == null) return pam.PAM_CONV_ERR;
    defer {
        for (0..4) |i| if (responses[i].resp != null) {
            std.crypto.secureZero(u8, std.mem.span(responses[i].resp));
            std.c.free(responses[i].resp);
        };
        std.c.free(responses);
    }
    if (responses[2].resp == null or responses[3].resp == null) return pam.PAM_AUTH_ERR;
    return if (std.mem.eql(u8, std.mem.span(responses[2].resp), "fixture-user") and std.mem.eql(u8, std.mem.span(responses[3].resp), "fixture-secret")) pam.PAM_SUCCESS else pam.PAM_AUTH_ERR;
}
export fn pam_sm_setcred(_: ?*pam.pam_handle_t, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return pam.PAM_SUCCESS;
}
export fn pam_sm_acct_mgmt(_: ?*pam.pam_handle_t, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return pam.PAM_SUCCESS;
}
