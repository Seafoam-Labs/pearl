const std = @import("std");
const glib = @import("glib2");
const i18n = @import("../ui/i18n.zig");
pub fn tr(en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
    const locale = glib.getLanguageNames()[0];
    return if (i18n.fromLocale(std.mem.span(locale)) == .de) de else en;
}
