const settings_portal = @import("portal/settings.zig");
const ffi = @import("portal/ffi.zig");
const Portal = @import("portal/types.zig").Portal;

test "theme settings disconnect and release on repeated startup and shutdown" {
    const testing = @import("std").testing;
    const gio = @import("gio2");
    const gobject = @import("gobject2");
    const bus = ffi.g_bus_get_sync(ffi.G_BUS_TYPE_SESSION, null, null);
    try testing.expect(bus != null);
    defer ffi.g_object_unref(bus);
    for (0..3) |_| {
        var p: Portal = .{ .bus = bus };
        settings_portal.portal_settings_init(&p);
        if (p.interface_settings == null) {
            try testing.expectEqual(@as(ffi.gulong, 0), p.interface_settings_changed);
            settings_portal.portal_settings_stop(&p);
            try testing.expect(p.settings == null and settings_portal.active == null);
            settings_portal.portal_settings_stop(&p);
            continue;
        }
        const theme = ffi.g_variant_ref(cached(&p, "org.gnome.desktop.interface/gtk-theme"));
        defer ffi.g_variant_unref(theme);
        settings_portal.portal_appearance(2, 0.1, 0.2, 0.3, 1, "Pearl font 18", "");
        try testing.expect(ffi.g_variant_equal(theme, cached(&p, "org.gnome.desktop.interface/gtk-theme")) != 0);
        try testing.expectEqualStrings("Pearl font 18", @import("std").mem.span(ffi.g_variant_get_string(cached(&p, "org.gnome.desktop.interface/font-name"), null)));
        try testing.expect(ffi.g_variant_get_boolean(cached(&p, "org.gnome.desktop.interface/enable-animations")) == 0);
        const settings: *gio.Settings = @ptrCast(p.interface_settings);
        try testing.expect(p.interface_settings_changed != 0);
        const held: *gobject.Object = @ptrCast(@alignCast(ffi.g_object_ref(settings)));
        var weak: gobject.WeakRef = undefined;
        weak.init(held);
        defer weak.clear();
        settings_portal.portal_settings_stop(&p);
        try testing.expect(p.interface_settings == null);
        try testing.expectEqual(@as(ffi.gulong, 0), p.interface_settings_changed);
        try testing.expect(p.settings == null and settings_portal.active == null);
        // A retained object can still signal after stop. A stale connection
        // would call setting() with the destroyed cache (fatal GLib warning).
        _ = settings.setString("gtk-theme", "After shutdown");
        settings.reset("gtk-theme");
        held.unref();
        const remaining = weak.get();
        if (remaining) |object| object.unref();
        try testing.expect(remaining == null);
        settings_portal.portal_settings_stop(&p);
    }
}

fn cached(p: *Portal, key: [*:0]const u8) ?*ffi.GVariant {
    return @ptrCast(@alignCast(ffi.g_hash_table_lookup(p.settings, key)));
}
