//! Bounded, cancellable HTTP. Public requests reject private resolved addresses,
//! including redirects; credentials are never forwarded across redirects.
const std = @import("std");
const gio = @import("gio2");
pub const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("pthread.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/file.h");
});
var once: c.pthread_once_t = c.PTHREAD_ONCE_INIT;
var initialized: bool = false;
fn init() callconv(.c) void {
    initialized = c.curl_global_init(c.CURL_GLOBAL_DEFAULT) == c.CURLE_OK;
}
pub const Options = struct {
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const []const u8 = &.{},
    max_bytes: usize = 2 * 1024 * 1024,
    timeout_seconds: u16 = 15,
    // Only the explicitly configured provider endpoint or our owned runtime.
    private_endpoint: bool = false,
    redirects: bool = true,
    output_fd: ?c_int = null,
    progress: ?*std.atomic.Value(u64) = null,
    resume_from: usize = 0,
    receiver: ?struct { context: *anyopaque, feed: *const fn (*anyopaque, []const u8) anyerror!void } = null,
    monitor: ?struct { context: *anyopaque, check: *const fn (*anyopaque) anyerror!void } = null,
};
pub const Response = struct { bytes: []const u8, status: c_long, content_type: []const u8 };
const Transfer = struct {
    a: std.mem.Allocator,
    opts: Options,
    cancel: *gio.Cancellable,
    data: std.ArrayList(u8) = .empty,
    received: usize = 0,
    failure: ?anyerror = null,
};
fn write(ptr: [*]u8, size: usize, n: usize, state: *Transfer) callconv(.c) usize {
    const len = std.math.mul(usize, size, n) catch return 0;
    if (state.cancel.isCancelled() != 0) return 0;
    if (len > state.opts.max_bytes -| state.received) {
        state.failure = error.ResponseTooLarge;
        return 0;
    }
    if (state.opts.receiver) |receiver| {
        receiver.feed(receiver.context, ptr[0..len]) catch |err| {
            state.failure = err;
            return 0;
        };
    } else if (state.opts.output_fd) |fd| {
        var offset: usize = 0;
        while (offset < len) {
            const count = std.c.write(fd, ptr[offset..len].ptr, len - offset);
            if (count <= 0) {
                state.failure = error.DownloadWriteFailed;
                return 0;
            }
            offset += @intCast(count);
        }
    } else state.data.appendSlice(state.a, ptr[0..len]) catch {
        state.failure = error.OutOfMemory;
        return 0;
    };
    state.received += len;
    if (state.opts.progress) |p| p.store(state.received + state.opts.resume_from, .monotonic);
    return len;
}
fn progress(state: *Transfer, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    if (state.opts.monitor) |monitor| monitor.check(monitor.context) catch |err| {
        state.failure = err;
        return 1;
    };
    return state.cancel.isCancelled();
}
pub fn publicV4(ip: [4]u8) bool {
    return !(ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or ip[0] >= 224 or
        (ip[0] == 169 and ip[1] == 254) or (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or
        (ip[0] == 192 and (ip[1] == 168 or ip[1] == 0)) or (ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127) or
        (ip[0] == 198 and (ip[1] == 18 or ip[1] == 19)));
}
fn openSocket(state: *Transfer, _: c.curlsocktype, address: *c.curl_sockaddr) callconv(.c) c.curl_socket_t {
    if (!state.opts.private_endpoint) {
        if (address.family == c.AF_INET) {
            const addr: *const c.sockaddr_in = @ptrCast(@alignCast(&address.addr));
            const bytes: [4]u8 = @bitCast(addr.sin_addr.s_addr);
            if (!publicV4(bytes)) return c.CURL_SOCKET_BAD;
        } else if (address.family == c.AF_INET6) {
            const addr: *const c.sockaddr_in6 = @ptrCast(@alignCast(&address.addr));
            const bytes: *const [16]u8 = @ptrCast(&addr.sin6_addr);
            // Only global unicast; excludes mapped IPv4, link/local/ULA and multicast.
            if (bytes[0] & 0xe0 != 0x20 or (bytes[0] == 0x20 and bytes[1] == 1 and bytes[2] == 0 and bytes[3] == 0)) return c.CURL_SOCKET_BAD;
        } else return c.CURL_SOCKET_BAD;
    }
    return c.socket(address.family, address.socktype | c.SOCK_CLOEXEC, address.protocol);
}
pub fn safeUrl(url: []const u8, private: bool) !void {
    if (url.len == 0 or url.len > 8192) return error.InvalidUrl;
    for (url) |ch| if (ch < 32 or ch == 127) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") and !(private and std.mem.eql(u8, uri.scheme, "http"))) return error.InvalidUrl;
    if (uri.user != null or uri.password != null or uri.host == null) return error.InvalidUrl;
}
pub fn request(a: std.mem.Allocator, opts: Options, cancel: *gio.Cancellable) !Response {
    try safeUrl(opts.url, opts.private_endpoint);
    if (cancel.isCancelled() != 0) return error.Cancelled;
    if (c.pthread_once(&once, init) != 0 or !initialized) return error.NetworkUnavailable;
    const handle = c.curl_easy_init() orelse return error.NetworkUnavailable;
    defer c.curl_easy_cleanup(handle);
    var transfer: Transfer = .{ .a = a, .opts = opts, .cancel = cancel };
    errdefer transfer.data.deinit(a);
    const address = try a.dupeZ(u8, opts.url);
    defer a.free(address);
    var headers: ?*c.curl_slist = null;
    defer c.curl_slist_free_all(headers);
    for (opts.headers) |h| {
        if (std.mem.indexOfAny(u8, h, "\r\n\x00") != null) return error.InvalidHeader;
        const z = try a.dupeZ(u8, h);
        defer a.free(z);
        headers = c.curl_slist_append(headers, z) orelse return error.OutOfMemory;
    }
    try option(handle, c.CURLOPT_URL, address.ptr);
    try option(handle, c.CURLOPT_USERAGENT, @as([*:0]const u8, "Pearl-Assistant/1"));
    try option(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, if (opts.private_endpoint) "http,https" else "https"));
    try option(handle, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "https"));
    try option(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, @intFromBool(opts.redirects and !opts.private_endpoint and opts.headers.len == 0)));
    try option(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 3));
    try option(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 5));
    try option(handle, c.CURLOPT_TIMEOUT, @as(c_long, opts.timeout_seconds));
    try option(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try option(handle, c.CURLOPT_PROXY, @as([*:0]const u8, ""));
    try option(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));
    try option(handle, c.CURLOPT_WRITEFUNCTION, &write);
    try option(handle, c.CURLOPT_WRITEDATA, &transfer);
    try option(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    try option(handle, c.CURLOPT_XFERINFOFUNCTION, &progress);
    try option(handle, c.CURLOPT_XFERINFODATA, &transfer);
    try option(handle, c.CURLOPT_OPENSOCKETFUNCTION, &openSocket);
    try option(handle, c.CURLOPT_OPENSOCKETDATA, &transfer);
    try option(handle, c.CURLOPT_HTTPHEADER, headers);
    if (opts.resume_from > 0) try option(handle, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, @intCast(opts.resume_from)));
    if (opts.body) |body| {
        try option(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        try option(handle, c.CURLOPT_POSTFIELDS, body.ptr);
    }
    if (c.curl_easy_perform(handle) != c.CURLE_OK) return transfer.failure orelse if (cancel.isCancelled() != 0) error.Cancelled else error.RequestFailed;
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status);
    var mime: ?[*:0]u8 = null;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_CONTENT_TYPE, &mime);
    return .{ .bytes = try transfer.data.toOwnedSlice(a), .status = status, .content_type = try a.dupe(u8, if (mime) |m| std.mem.span(m) else "") };
}
fn option(handle: ?*c.CURL, key: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, key, value) != c.CURLE_OK) return error.NetworkUnavailable;
}
pub fn encode(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) try out.append(a, ch) else try out.appendSlice(a, &.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
    return out.toOwnedSlice(a);
}
test "public requests reject local networks and credential-bearing URLs" {
    try std.testing.expect(!publicV4(.{ 127, 0, 0, 1 }));
    try std.testing.expect(!publicV4(.{ 169, 254, 169, 254 }));
    try std.testing.expect(!publicV4(.{ 10, 0, 0, 2 }));
    try std.testing.expect(publicV4(.{ 8, 8, 8, 8 }));
    try std.testing.expectError(error.InvalidUrl, safeUrl("https://a:b@example.org", false));
    try std.testing.expectError(error.InvalidUrl, safeUrl("file:///etc/passwd", false));
}
