//! Static design assets only. Run from the repository root with Zig 0.16.
const std = @import("std");
const Canvas = struct {
    a: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
    light: bool,
    fn out(s: *Canvas, comptime fmt: []const u8, args: anytype) !void {
        try s.data.appendSlice(s.a, try std.fmt.allocPrint(s.a, fmt, args));
    }
    fn rect(s: *Canvas, x: i32, y: i32, w: i32, h: i32, r: i32, class: []const u8) !void {
        try s.out("<rect x='{d}' y='{d}' width='{d}' height='{d}' rx='{d}' class='{s}'/>\n", .{ x, y, w, h, r, class });
    }
    fn text(s: *Canvas, x: i32, y: i32, class: []const u8, value: []const u8) !void {
        try s.out("<text x='{d}' y='{d}' class='{s}'>{s}</text>\n", .{ x, y, class, value });
    }
    fn button(s: *Canvas, x: i32, y: i32, w: i32, value: []const u8, primary: bool) !void {
        try s.rect(x, y, w, 36, 18, if (primary) "accent" else "button");
        try s.text(x + @divTrunc(w, 2), y + 23, if (primary) "on-accent center" else "center", value);
    }
    fn toggle(s: *Canvas, x: i32, y: i32, on: bool) !void {
        try s.rect(x, y, 44, 24, 12, if (on) "accent" else "button");
        try s.out("<circle cx='{d}' cy='{d}' r='8' class='{s}'/>\n", .{ x + @as(i32, if (on) 31 else 13), y + 12, if (on) "knob-on" else "knob" });
    }
    fn row(s: *Canvas, x: i32, y: i32, w: i32, name: []const u8, value: []const u8) !void {
        try s.text(x + 20, y + 28, "", name);
        try s.text(x + w - 20, y + 28, "right muted", value);
    }
    fn disclosure(s: *Canvas, x: i32, y: i32, w: i32, title: []const u8, summary: []const u8) !void {
        try s.rect(x, y, w, 76, 16, "card");
        try s.text(x + 20, y + 29, "strong", title);
        try s.text(x + 20, y + 53, "muted small", summary);
        try s.text(x + w - 24, y + 42, "right muted", "›");
    }
    fn scene(s: *Canvas, x: i32, y: i32, w: i32, h: i32) !void {
        try s.rect(x, y, w, h, 12, "wallpaper");
        try s.rect(x + 10, y + 10, @divTrunc(w, 3), 15, 7, "mini-surface");
        try s.rect(x + w - 77, y + 10, 67, 15, 7, "mini-surface");
        try s.rect(x + @divTrunc(w, 2) - 24, y + 10, 48, 15, 7, "mini-surface");
        try s.rect(x + @divTrunc(w, 4), y + 44, @divTrunc(w, 2), h - 78, 8, "mini-surface");
        try s.rect(x + @divTrunc(w, 4) + 12, y + 57, 50, 5, 2, "mini-muted");
        try s.rect(x + @divTrunc(w, 4) + 12, y + 71, @divTrunc(w, 2) - 24, 12, 5, "mini-selected");
        try s.rect(x + @divTrunc(w, 2) - 47, y + h - 27, 94, 19, 8, "mini-surface");
        for (0..4) |i| try s.rect(x + @divTrunc(w, 2) - 36 + @as(i32, @intCast(i)) * 21, y + h - 23, 12, 11, 3, "mini-selected");
    }
    fn theme(s: *Canvas, x: i32, y: i32, w: i32, narrow: bool) !void {
        try s.rect(x, y, w, if (narrow) 354 else 258, 16, "card");
        try s.text(x + 20, y + 32, "section", "Theme &amp; colors");
        const labels = [_][]const u8{ "Material", "Dynamic", "GTK", "Community" };
        const subtitles = [_][]const u8{ "Built-in colors", "Wallpaper or seed", "System theme", "Installed themes" };
        const cols: i32 = if (narrow) 2 else 4;
        const tw = @divTrunc(w - 40 - (cols - 1) * 10, cols);
        for (labels, 0..) |label, i| {
            const n: i32 = @intCast(i);
            const tx = x + 20 + @mod(n, cols) * (tw + 10);
            const ty = y + 52 + @divTrunc(n, cols) * 96;
            try s.rect(tx, ty, tw, 86, 12, if (i == 1) "selected" else "choice");
            try s.text(tx + 12, ty + 25, "strong", label);
            try s.text(tx + tw - 12, ty + 25, "right", if (i == 1) "●" else "○");
            try s.text(tx + 12, ty + 48, "small muted", subtitles[i]);
            for (0..3) |j| try s.out("<circle cx='{d}' cy='{d}' r='5' fill='{s}'/>\n", .{ tx + 17 + @as(i32, @intCast(j)) * 16, ty + 68, ([_][]const u8{ "#d0bcff", "#b9c9eb", "#dcbcd3" })[j] });
        }
        const ry = y + @as(i32, if (narrow) 244 else 148);
        try s.row(x, ry, w, "Color variant", if (s.light) "Light   ⌄" else "Dark   ⌄");
        try s.row(x, ry + 45, w, "Colors from", "Wallpaper   ⌄");
        try s.text(x + 20, ry + 93, "small muted", "Colors update when you apply your wallpaper.");
    }
};

fn render(a: std.mem.Allocator, light: bool, narrow: bool, details: bool) ![]const u8 {
    var s: Canvas = .{ .a = a, .light = light };
    const width: i32 = if (narrow) 390 else 1280;
    const height: i32 = if (narrow) 1000 else 1120;
    try s.out("<svg xmlns='http://www.w3.org/2000/svg' width='{d}' height='{d}' viewBox='0 0 {d} {d}' role='img' aria-labelledby='title desc'>\n<title id='title'>Pearl Appearance redesign — {s}</title><desc id='desc'>Static proposed settings layout with shared navigation, draft preview, visual theme choices, grouped controls and a persistent Apply and save footer.</desc>\n", .{ width, height, width, height, if (details) "additional settings" else if (narrow) "narrow window" else if (light) "light" else "dark" });
    try s.out("<defs><linearGradient id='wall' x2='1' y2='1'><stop stop-color='#21192e'/><stop offset='.55' stop-color='#574078'/><stop offset='1' stop-color='#b398c7'/></linearGradient></defs><style>\ntext{{font-family:Inter,'DejaVu Sans',sans-serif;font-size:14px;fill:{s}}} .bg{{fill:{s}}}.sidebar{{fill:{s}}}.card{{fill:{s}}}.button,.choice{{fill:{s};stroke:{s}}}.selected{{fill:{s};stroke:{s};stroke-width:1.5}}.accent{{fill:{s}}}.on-accent{{fill:{s}}}.muted{{fill:{s}}}.strong{{font-weight:600}}.small{{font-size:12px}}.tiny{{font-size:10px;letter-spacing:1.2px}}.section{{font-size:17px;font-weight:600}}.heading{{font-size:30px;font-weight:500;letter-spacing:-.6px}}.center{{text-anchor:middle}}.right{{text-anchor:end}}.wallpaper{{fill:url(#wall)}}.mini-surface{{fill:{s}}}.mini-selected{{fill:#bba3eb}}.mini-muted{{fill:#9c91ad}}.knob{{fill:#c6c0ce}}.knob-on{{fill:{s}}}.line{{stroke:{s};fill:none}}\n</style>\n", .{
        @as([]const u8, if (light) "#29252e" else "#e7e1ec"), if (light) "#f8f5fa" else "#211f26", if (light) "#f0edf2" else "#1e1c21", if (light) "#eeebf1" else "#2b2831", if (light) "#f8f5fa" else "#302c37", if (light) "#d7d0df" else "#4b4554", if (light) "#e9ddff" else "#4f3787", if (light) "#6750a4" else "#d0bcff", if (light) "#6750a4" else "#d0bcff", if (light) "#ffffff" else "#381e72", if (light) "#655d70" else "#c4bbcf", if (light) "#eee8f6" else "#272130", if (light) "#ffffff" else "#381e72", if (light) "#d7d0df" else "#403a48",
    });
    try s.rect(0, 0, width, height, 16, "bg");
    try s.rect(0, 0, width, 52, 0, "sidebar");
    try s.text(22, 32, "strong", "●  Pearl Settings");
    try s.text(width - 22, 32, "right muted", "−   □   ×");
    if (!narrow) {
        try s.rect(0, 52, 220, height - 52, 0, "sidebar");
        const names = [_][]const u8{ "GENERAL", "Overview", "CONNECTIONS", "Network", "Bluetooth", "DEVICES", "Sound", "Power &amp; battery", "DESKTOP", "Appearance", "Assistant", "Bar &amp; dock", "Notifications", "SYSTEM", "System", "Session &amp; lock", "Aqueous", "Advanced", "Plugins" };
        var ny: i32 = 84;
        for (names, 0..) |name, i| {
            const group = i == 0 or i == 2 or i == 5 or i == 8 or i == 13;
            if (i == 9) try s.rect(12, ny - 25, 196, 42, 11, "selected");
            try s.text(24, ny, if (group) "tiny muted" else "", name);
            ny += if (group) 34 else 44;
        }
    } else try s.button(16, 65, 106, "☰  Sections", false);
    const x: i32 = if (narrow) 16 else 250;
    const w: i32 = if (narrow) 358 else 1000;
    const hy: i32 = if (narrow) 141 else 101;
    try s.text(x, hy, "heading", "Appearance");
    try s.text(x, hy + 26, "muted", "Make Pearl feel at home on your desktop.");
    if (details) {
        try s.text(x, 163, "small muted", "Appearance · continued below Wallpaper");
        try s.rect(x, 182, w, 226, 16, "card");
        try s.text(x + 20, 215, "section", "Text &amp; layout");
        try s.row(x, 232, w, "Font family", "System default");
        try s.row(x, 276, w, "Text size", "−     14 px     +");
        try s.row(x, 320, w, "Density", "Comfortable   ⌄");
        try s.row(x, 364, w, "Reduced motion", "");
        try s.toggle(x + w - 64, 374, false);
        try s.rect(x, 424, w, 166, 16, "card");
        try s.text(x + 20, 457, "section", "Desktop icons");
        try s.toggle(x + w - 64, 438, true);
        try s.row(x, 472, w, "Icon size", "48 px   ⌄");
        try s.row(x, 515, w, "Arrangement", "Automatic · Name   ⌄");
        try s.text(x + 20, 574, "muted small", "›  Display &amp; hidden files");
        try s.disclosure(x, 606, w, "Night Light", "Off · warmer screen colors on supported displays");
        try s.disclosure(x, 696, w, "Application appearance", "Window borders, Qt applications and application color profiles");
        try s.disclosure(x, 786, w, "Themes &amp; customization", "Installed and community themes, palette overrides and widget styles");
        try s.disclosure(x, 876, w, "Login screen", "Review appearance before copying it to the login screen");
        try s.text(x, 982, "small muted", "Expand a section to edit its settings. Errors remain visible when collapsed.");
    } else if (narrow) {
        try s.rect(x, 188, w, 240, 16, "card");
        try s.text(x + 16, 218, "strong", "Desktop preview");
        try s.scene(x + 16, 234, w - 32, 146);
        try s.text(x + 16, 407, "muted small", "Draft preview · desktop changes after Apply");
        try s.theme(x, 444, w, true);
        try s.rect(x, 814, w, 100, 16, "card");
        try s.text(x + 20, 848, "section", "Wallpaper");
        try s.text(x + 20, 884, "muted small", "Dusk.png · Cover");
        try s.button(x + 185, 862, 153, "Choose image…", false);
    } else {
        try s.rect(x, 150, w, 194, 16, "card");
        try s.scene(x + 18, 168, 338, 158);
        try s.text(x + 380, 192, "section", "Desktop preview");
        try s.text(x + 380, 222, "", "Dynamic Material · Wallpaper colors");
        try s.text(x + 380, 249, "muted small", "Preview your draft before changing the desktop.");
        try s.text(x + 380, 271, "muted small", "Bar and dock use your current layout.");
        try s.rect(x + 380, 286, 106, 36, 18, "selected");
        try s.text(x + 433, 309, "small center", "Draft preview");
        try s.text(x + 505, 309, "muted small", "Illustrative layout");
        try s.theme(x, 360, w, false);
        try s.rect(x, 634, w, 174, 16, "card");
        try s.text(x + 20, 668, "section", "Wallpaper");
        try s.rect(x + 20, 686, 120, 64, 8, "wallpaper");
        try s.text(x + 158, 709, "strong", "Dusk.png");
        try s.text(x + 158, 734, "muted small", "Cover · Pictures / Wallpapers");
        try s.button(x + w - 172, 695, 152, "Choose image…", false);
        try s.text(x + 20, 784, "muted", "›  Image options &amp; slideshow");
        try s.disclosure(x, 824, w, "Text &amp; layout", "System font · 14 px · Comfortable spacing");
        try s.disclosure(x, 916, w, "Desktop icons", "On · 48 px · Automatic arrangement");
    }
    const fy = height - (if (narrow) @as(i32, 78) else 78);
    try s.rect(if (narrow) 0 else 220, fy, width - (if (narrow) @as(i32, 0) else 220), 78, 0, "bg");
    try s.out("<path d='M{d} {d}H{d}' class='line'/>\n", .{ if (narrow) @as(i32, 0) else 220, fy, width });
    try s.text(x, fy + (if (narrow) @as(i32, 22) else 30), "small muted", if (narrow) "Unsaved Pearl preferences" else "Unsaved Pearl preferences · shared across tabs");
    if (!narrow) try s.text(x, fy + 51, "small muted", "Your desktop changes after Apply &amp; save.");
    try s.button(width - 260, fy + (if (narrow) @as(i32, 32) else 21), 92, "Discard", false);
    try s.button(width - 156, fy + (if (narrow) @as(i32, 32) else 21), 140, "Apply &amp; save", true);
    if (!narrow) try s.rect(width - 8, if (details) 642 else 155, 3, 218, 2, "mini-muted");
    try s.out("</svg>\n", .{});
    return s.data.items;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const variants = [_]struct { name: []const u8, light: bool = false, narrow: bool = false, details: bool = false }{
        .{ .name = "desktop" }, .{ .name = "light", .light = true }, .{ .name = "narrow", .narrow = true }, .{ .name = "details", .details = true },
    };
    for (variants) |v| {
        const path = try std.fmt.allocPrint(a, "docs/mockups/appearance/{s}.svg", .{v.name});
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, try render(a, v.light, v.narrow, v.details));
    }
}
