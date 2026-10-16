//! Static System layout drawings; all generation logic is Zig 0.16.
//! SVG is an editable vector asset, not a web implementation.
const std = @import("std");
const Canvas = struct {
    a: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
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
        try s.rect(x, y, w, 44, 12, if (primary) "accent" else "button");
        try s.text(x + @divTrunc(w, 2), y + 28, if (primary) "on-accent center strong" else "center", value);
    }
    fn disclosure(s: *Canvas, x: i32, y: i32, w: i32, title: []const u8, summary: []const u8) !void {
        try s.rect(x, y, w, 78, 16, "card");
        try s.text(x + 20, y + 30, "strong", title);
        try s.text(x + 20, y + 55, "small muted", summary);
        try s.text(x + w - 20, y + 42, "right", "›");
    }
    fn modes(s: *Canvas, x: i32, y: i32, w: i32, narrow: bool) !void {
        const names = [_][]const u8{ "Auto", "Gaming", "Low latency", "Power saver", "Server" };
        const tw = if (narrow) w else @divTrunc(w - 20, 3);
        for (names, 0..) |name, i| {
            const n: i32 = @intCast(i);
            const tx = x + if (narrow) @as(i32, 0) else @mod(n, 3) * (tw + 10);
            const ty = y + if (narrow) n * 52 else @divTrunc(n, 3) * 58;
            try s.rect(tx, ty, tw, if (narrow) 44 else 50, 12, if (i == 1) "selected" else "button");
            try s.text(tx + 14, ty + (if (narrow) @as(i32, 28) else 31), "", if (i == 1) "●" else "○");
            try s.text(tx + 40, ty + (if (narrow) @as(i32, 28) else 31), "strong", name);
        }
    }
};
const View = enum { desktop, light, narrow, details, states };

fn overview(s: *Canvas, narrow: bool, x: i32, w: i32) !void {
    const y: i32 = if (narrow) 190 else 150;
    try s.rect(x, y, w, if (narrow) 180 else 146, 16, "card");
    try s.text(x + 20, y + 30, "small muted", "CURRENTLY RUNNING");
    try s.text(x + 20, y + 67, "runtime", "scx_bpfland");
    try s.text(x + 20, y + 94, "muted", "Auto mode · Managed by scx_loader");
    if (narrow) {
        try s.button(x + 20, y + 116, 194, "Use kernel default", false);
        try s.button(x + w - 122, y + 16, 102, "Refresh", false);
    } else {
        try s.rect(x + 220, y + 43, 80, 28, 14, "selected");
        try s.text(x + 260, y + 62, "small center", "Running");
        try s.text(x + 20, y + 122, "small muted", "Observed runtime · Independent of your selection below");
        try s.button(x + w - 122, y + 20, 102, "Refresh", false);
        try s.button(x + w - 214, y + 82, 194, "Use kernel default", false);
    }
    const sy = y + (if (narrow) @as(i32, 196) else 162);
    try s.rect(x, sy, w, if (narrow) 510 else 354, 16, "card");
    try s.text(x + 20, sy + 32, "section", "CPU scheduler");
    try s.text(x + w - 20, sy + 32, "small right muted", "Not applied");
    if (narrow) {
        try s.text(x + 20, sy + 59, "small muted", "Scheduler · 2 installed");
        try s.rect(x + 20, sy + 72, w - 40, 44, 10, "button");
        try s.text(x + 34, sy + 100, "", "scx_bpfland");
        try s.text(x + w - 34, sy + 100, "right", "⌄");
        try s.text(x + 20, sy + 141, "small muted", "Mode");
        try s.modes(x + 20, sy + 152, w - 40, true);
        try s.text(x + 20, sy + 426, "small muted", "Uses configured arguments for Gaming.");
        try s.text(x + 20, sy + 447, "small muted", "Applies now to all apps. Boot unchanged.");
        try s.button(x + 20, sy + 458, w - 40, "Apply scheduler", true);
    } else {
        try s.text(x + 20, sy + 73, "muted", "Scheduler");
        try s.rect(x + 212, sy + 50, w - 232, 44, 10, "button");
        try s.text(x + 228, sy + 78, "", "scx_bpfland");
        try s.text(x + w - 36, sy + 78, "right", "⌄");
        try s.text(x + 20, sy + 114, "small muted", "2 installed schedulers · Inspect configuration in Scheduler details");
        try s.text(x + 20, sy + 144, "small muted", "Mode");
        try s.modes(x + 20, sy + 158, w - 40, false);
        try s.text(x + 20, sy + 286, "small muted", "Uses configured arguments for Gaming.");
        try s.text(x + 20, sy + 325, "small muted", "Applies now to all applications. Boot settings stay unchanged.");
        try s.button(x + w - 202, sy + 302, 182, "Apply scheduler", true);
    }
    const dy = sy + (if (narrow) @as(i32, 526) else 370);
    try s.disclosure(x, dy, w, "Scheduler details", "2 installed · Selected mode arguments");
    try s.disclosure(x, dy + 94, w, "Startup configuration", "scx_bpfland · Auto · Read-only");
    try s.text(x + 4, dy + 204, "small muted", if (narrow) "Runtime changes do not edit boot settings." else "Startup configuration is managed by scx_loader. Applying a scheduler changes runtime state only.");
}

fn details(s: *Canvas, x: i32, w: i32) !void {
    try s.text(x, 160, "small muted", "Expanded sections · Example configuration · Alternate scroll position");
    try s.rect(x, 182, w, 296, 16, "card");
    try s.text(x + 20, 216, "section", "Scheduler details");
    try s.text(x + w - 20, 216, "right", "⌄");
    try s.text(x + 20, 246, "muted", "2 installed · 1 missing executable");
    try s.text(x + 20, 286, "strong", "Selected mode arguments");
    try s.text(x + w - 20, 286, "right muted", "scx_bpfland · Gaming");
    try s.rect(x + 20, 302, w - 40, 52, 10, "button");
    try s.text(x + 36, 334, "mono", "[&quot;-m&quot;, &quot;all&quot;]");
    try s.text(x + 20, 382, "small muted", "Read-only resolved arguments. The loader supplies these when you apply this mode.");
    try s.text(x + 20, 422, "strong", "Missing executable");
    try s.text(x + w - 20, 422, "right mono muted", "scx_missing");
    try s.text(x + 20, 451, "small muted", "Unavailable in the scheduler selector. Refresh after installing it outside Pearl.");
    try s.rect(x, 494, w, 204, 16, "card");
    try s.text(x + 20, 528, "section", "Startup configuration");
    try s.text(x + w - 20, 528, "right", "⌄");
    try s.text(x + 20, 570, "", "Configured scheduler");
    try s.text(x + w - 20, 570, "right muted", "scx_bpfland");
    try s.text(x + 20, 610, "", "Configured mode");
    try s.text(x + w - 20, 610, "right muted", "Auto");
    try s.text(x + 20, 657, "small muted", "Read-only · Managed by scx_loader configuration. Runtime actions do not change these values.");
    try s.rect(x, 730, w, 132, 16, "card");
    try s.text(x + 20, 764, "section", "When a mode has no distinct arguments");
    try s.text(x + 20, 798, "muted", "Show this explanation directly below the mode choices:");
    try s.text(x + 20, 832, "", "No distinct arguments are configured for Gaming. Uses scheduler defaults.");
    try s.text(x + 4, 896, "small muted", "The last card is a copy example, not an additional section in the native page.");
}

fn states(s: *Canvas, x: i32, w: i32) !void {
    try s.text(x, 160, "small muted", "Independent examples · Keep observed runtime and pending selection separate");
    const titles = [_][]const u8{ "Kernel default", "Currently applied", "Applying scheduler…", "Scheduler tools unavailable", "Scheduler change failed", "External or unknown scheduler" };
    const lines = [_][3][]const u8{
        .{ "No sched-ext scheduler is active.", "Loader and kernel state agree.", "Use kernel default is disabled." },
        .{ "Running: scx_bpfland · Gaming", "Selection: scx_bpfland · Gaming", "Apply is disabled until the choice changes." },
        .{ "Selected: scx_bpfland · Gaming", "Waiting for observed runtime confirmation.", "Competing actions are disabled." },
        .{ "scxctl was not found.", "Scheduler changes are unavailable.", "Install outside Pearl, then refresh." },
        .{ "The loader denied the requested change.", "Selection retained: scx_bpfland · Gaming", "Review observed status before retrying." },
        .{ "The kernel and loader do not agree.", "Current ownership is not confirmed.", "Do not show Kernel default as active." },
    };
    const actions = [_][]const u8{ "Choose a scheduler below", "No change to apply", "Applying…", "Refresh", "Refresh", "Refresh" };
    const cw = @divTrunc(w - 16, 2);
    for (titles, 0..) |title, i| {
        const n: i32 = @intCast(i);
        const cx = x + @mod(n, 2) * (cw + 16);
        const cy = 182 + @divTrunc(n, 2) * 238;
        try s.rect(cx, cy, cw, 222, 16, "card");
        try s.text(cx + 20, cy + 34, "section", title);
        for (lines[i], 0..) |line, j| try s.text(cx + 20, cy + 72 + @as(i32, @intCast(j)) * 25, "small muted", line);
        if (i < 3) {
            try s.text(cx + 20, cy + 185, "small muted", actions[i]);
        } else try s.button(cx + 20, cy + 156, 120, actions[i], false);
    }
}

fn render(a: std.mem.Allocator, view: View) ![]const u8 {
    var s: Canvas = .{ .a = a };
    const light = view == .light;
    const narrow = view == .narrow;
    const width: i32 = if (narrow) 390 else 1200;
    const height: i32 = if (narrow) 1220 else 1000;
    try s.out("<svg xmlns='http://www.w3.org/2000/svg' width='{d}' height='{d}' viewBox='0 0 {d} {d}' role='img' aria-labelledby='title desc'><title id='title'>System layout proposal — {s}</title><desc id='desc'>Static Pearl Settings design. Current scheduler and staged selection are separate. Runtime actions do not change boot settings. Data is illustrative.</desc>\n", .{ width, height, width, height, @tagName(view) });
    try s.out("<style>text{{font-family:Inter,'DejaVu Sans',sans-serif;font-size:14px;fill:{s}}}.bg{{fill:{s}}}.sidebar{{fill:{s}}}.card{{fill:{s}}}.button{{fill:{s};stroke:{s}}}.selected{{fill:{s};stroke:{s}}}.accent{{fill:{s}}}.on-accent{{fill:{s}}}.muted{{fill:{s}}}.strong{{font-weight:600}}.small{{font-size:12px}}.tiny{{font-size:10px;letter-spacing:1.4px}}.section{{font-size:17px;font-weight:600}}.runtime{{font-size:26px;font-weight:500}}.heading{{font-size:30px;font-weight:500;letter-spacing:-.6px}}.center{{text-anchor:middle}}.right{{text-anchor:end}}.mono{{font-family:'DejaVu Sans Mono',monospace;font-size:13px}}.line{{stroke:{s};fill:none}}</style>\n", .{
        @as([]const u8, if (light) "#29252e" else "#e7e1ec"), if (light) "#f8f5fa" else "#211f26", if (light) "#f0edf2" else "#1e1c21", if (light) "#eeebf1" else "#2b2831", if (light) "#f8f5fa" else "#302c37", if (light) "#d7d0df" else "#4b4554", if (light) "#e9ddff" else "#4f3787", if (light) "#6750a4" else "#d0bcff", if (light) "#6750a4" else "#d0bcff", if (light) "#ffffff" else "#381e72", if (light) "#655d70" else "#c4bbcf", if (light) "#d7d0df" else "#403a48",
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
            if (i == 14) try s.rect(12, ny - 25, 196, 42, 11, "selected");
            try s.text(24, ny, if (group) "tiny muted" else "", name);
            ny += if (group) 34 else 44;
        }
    } else try s.button(16, 65, 106, "☰  Sections", false);
    const x: i32 = if (narrow) 16 else 250;
    const w: i32 = if (narrow) 358 else 920;
    const hy: i32 = if (narrow) 147 else 101;
    try s.text(x, hy, "heading", "System");
    try s.text(x, hy + 26, "muted", "Manage CPU scheduling.");
    switch (view) {
        .desktop, .light, .narrow => try overview(&s, narrow, x, w),
        .details => try details(&s, x, w),
        .states => try states(&s, x, w),
    }
    const fy = height - 72;
    try s.rect(if (narrow) 0 else 220, fy, width - (if (narrow) @as(i32, 0) else 220), 72, 0, "bg");
    try s.out("<path d='M{d} {d}H{d}' class='line'/>\n", .{ if (narrow) @as(i32, 0) else 220, fy, width });
    try s.text(x, fy + 28, "small muted", if (narrow) "Choose a mode, then use Apply scheduler." else "Select a scheduler and mode, then use Apply scheduler. Boot defaults are unchanged.");
    try s.text(x, fy + 50, "small muted", if (narrow) "Boot defaults are unchanged." else "System actions are separate from saved Pearl preferences.");
    try s.out("</svg>\n", .{});
    return s.data.items;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    for (std.enums.values(View)) |view| {
        const path = try std.fmt.allocPrint(a, "docs/mockups/system-layout/{s}.svg", .{@tagName(view)});
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, try render(a, view));
    }
}
