//! Isolated PAM module; only the non-installed test locker uses this stack.
const std = @import("std");
const pam = @import("pam");
export fn pam_sm_authenticate(handle: ?*pam.pam_handle_t, _: c_int, argc: c_int, argv: [*c][*c]const u8) c_int {
    const mode = if (argc > 0) std.mem.span(argv[0]) else "normal";
    if (std.mem.startsWith(u8, mode, "policy-")) {
        if (argc > 1) {
            var item: ?*const anyopaque = null;
            if (pam.pam_get_item(handle, pam.PAM_CONV, &item) != pam.PAM_SUCCESS or item == null) return pam.PAM_SYSTEM_ERR;
            const conv: *const pam.pam_conv = @ptrCast(@alignCast(item.?));
            if (!message(conv, pam.PAM_TEXT_INFO, argv[1], null)) return pam.PAM_CONV_ERR;
        }
        return policyResult(mode);
    }
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
    if (std.mem.startsWith(u8, mode, "fingerprint")) {
        if (std.mem.eql(u8, mode, "fingerprint-input-status")) {
            if (!message(conv, pam.PAM_PROMPT_ECHO_OFF, "Fixture password:", "fixture-secret")) return pam.PAM_AUTH_ERR;
        }
        if (!message(conv, pam.PAM_TEXT_INFO, "Touch the fingerprint reader", null)) return pam.PAM_CONV_ERR;
        if (std.mem.eql(u8, mode, "fingerprint-wait")) {
            _ = pam.sleep(120);
            return pam.PAM_AUTH_ERR;
        }
        _ = pam.sleep(1);
        if (!message(conv, pam.PAM_ERROR_MSG, "Remove finger and retry", null)) return pam.PAM_CONV_ERR;
        if (std.mem.eql(u8, mode, "fingerprint-fallback") or std.mem.eql(u8, mode, "fingerprint-factor")) {
            if (!message(conv, pam.PAM_PROMPT_ECHO_OFF, "Fixture password:", "fixture-secret")) return pam.PAM_AUTH_ERR;
        }
        return pam.PAM_SUCCESS;
    }
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
fn policyResult(mode: []const u8) c_int {
    if (std.mem.eql(u8, mode, "policy-success")) return pam.PAM_SUCCESS;
    if (std.mem.eql(u8, mode, "policy-unavailable")) return pam.PAM_AUTHINFO_UNAVAIL;
    if (std.mem.eql(u8, mode, "policy-maxtries")) return pam.PAM_MAXTRIES;
    if (std.mem.eql(u8, mode, "policy-ignore")) return pam.PAM_IGNORE;
    if (std.mem.eql(u8, mode, "policy-error")) return pam.PAM_SYSTEM_ERR;
    return pam.PAM_AUTH_ERR;
}
fn message(conv: *const pam.pam_conv, style: c_int, text: [*:0]const u8, expected: ?[]const u8) bool {
    var msg: pam.pam_message = .{ .msg_style = style, .msg = text };
    var ptrs = [_][*c]const pam.pam_message{&msg};
    var responses: [*c]pam.pam_response = null;
    if (conv.conv.?(1, &ptrs, &responses, conv.appdata_ptr) != pam.PAM_SUCCESS or responses == null) return false;
    defer {
        if (responses[0].resp != null) {
            std.crypto.secureZero(u8, std.mem.span(responses[0].resp));
            std.c.free(responses[0].resp);
        }
        std.c.free(responses);
    }
    return if (expected) |value| responses[0].resp != null and std.mem.eql(u8, value, std.mem.span(responses[0].resp)) else responses[0].resp == null;
}
export fn pam_sm_setcred(_: ?*pam.pam_handle_t, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return pam.PAM_SUCCESS;
}
export fn pam_sm_acct_mgmt(_: ?*pam.pam_handle_t, _: c_int, argc: c_int, argv: [*c][*c]const u8) c_int {
    if (argc > 0) return policyResult(std.mem.span(argv[0]));
    return pam.PAM_SUCCESS;
}
