//! Explicit M0 reduced-feature policy, independent of benchmark workloads.
//! GtkSourceView 5.22 reparses/retags whole suffixes; Pango lays out whole
//! paragraphs. These limits bound presentation work without changing source text.
//! A future incremental highlighter/virtualized paragraph renderer can lift them.

const u = @import("../c.zig");
const c = u.c;
pub const syntax_char_limit = 512 * 1024;
pub const paragraph_byte_limit = 16 * 1024;
pub const excerpt_char_limit = 2048;
const key = "coral-presentation-policy";
pub const Policy = struct {
    buffer: *c.GtkTextBuffer,
    language: ?*c.GtkSourceLanguage = null,
    limited: bool = false,
    long_line: bool = false,
    applying: bool = false,
    start: c_int = 0,
    added_chars: c_int = 0,
    idle: c_uint = 0,

    fn refresh(self: *Policy, all: bool) void {
        var iter: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &iter, if (all or self.long_line) 0 else self.start);
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &end, if (all or self.long_line) -1 else self.start + self.added_chars);
        const last = c.gtk_text_iter_get_line(&end);
        self.long_line = false;
        while (true) {
            if (c.gtk_text_iter_get_bytes_in_line(&iter) > paragraph_byte_limit) {
                self.long_line = true;
                break;
            }
            if (c.gtk_text_iter_get_line(&iter) >= last or c.gtk_text_iter_forward_line(&iter) == 0) break;
        }
        self.limited = self.long_line or c.gtk_text_buffer_get_char_count(self.buffer) >= syntax_char_limit;
        // changed runs INSIDE GtkSourceBuffer's insert/delete vfunc. Replacing
        // its engine there lets the outer vfunc feed an old edit into a new tree.
        // Apply before GtkSource's high-idle parser/layout, but after that stack
        // unwinds. The layout guard can act on long_line synchronously.
        const desired = if (self.limited) null else self.language;
        if (all) self.applyLanguage() else if (self.idle == 0 and c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, self.buffer)) != desired) {
            self.idle = c.g_idle_add_full(c.G_PRIORITY_HIGH, &applyIdle, self, null);
        }
    }
    fn applyIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(Policy, data.?);
        self.idle = 0;
        self.applyLanguage();
        return 0;
    }
    fn applyLanguage(self: *Policy) void {
        self.applying = true;
        defer self.applying = false;
        c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, self.buffer), if (self.limited) null else self.language);
    }
    fn remember(self: *Policy) void {
        const language = c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, self.buffer));
        if (language == self.language) return;
        if (language) |value| _ = c.g_object_ref(value);
        if (self.language) |value| c.g_object_unref(value);
        self.language = language;
    }
    fn inserted(_: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Policy, data.?);
        self.start = c.gtk_text_iter_get_offset(at);
        self.added_chars = @intCast(c.g_utf8_strlen(text, len));
    }
    fn deleted(_: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, _: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Policy, data.?);
        self.start = c.gtk_text_iter_get_offset(at);
        self.added_chars = 0;
    }
    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        u.cast(Policy, data.?).refresh(false);
    }
    fn languageChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Policy, data.?);
        if (self.applying) return;
        self.remember();
        self.applyLanguage();
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Policy, data.?);
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.language) |language| c.g_object_unref(language);
        u.a.destroy(self);
    }
};
/// One policy per canonical buffer, owned by GObject, surviving all view churn.
/// Attach before projection callbacks so text echo observes the updated policy.
pub fn attach(buffer: *c.GtkTextBuffer) !*Policy {
    if (get(buffer)) |policy| return policy;
    const policy = try u.a.create(Policy);
    policy.* = .{ .buffer = buffer };
    policy.remember();
    c.g_object_set_data_full(u.cast(c.GObject, buffer), key, policy, &Policy.destroy);
    u.connect(buffer, "insert-text", &Policy.inserted, policy);
    u.connect(buffer, "delete-range", &Policy.deleted, policy);
    u.connect(buffer, "changed", &Policy.changed, policy);
    u.connect(buffer, "notify::language", &Policy.languageChanged, policy);
    policy.refresh(true);
    return policy;
}
pub fn get(buffer: *c.GtkTextBuffer) ?*Policy {
    const data = c.g_object_get_data(u.cast(c.GObject, buffer), key) orelse return null;
    return u.cast(Policy, data);
}
pub fn limited(buffer: *c.GtkTextBuffer) bool {
    return if (get(buffer)) |policy| policy.limited else false;
}
