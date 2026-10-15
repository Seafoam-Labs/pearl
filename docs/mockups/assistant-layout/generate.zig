//! Static SVG design assets. Run from the repository root with Zig 0.16.
//! SVG is the editable drawing format; all generation logic is Zig.
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
        try s.rect(x, y, w, 40, 12, if (primary) "accent" else "button");
        try s.text(x + @divTrunc(w, 2), y + 25, if (primary) "on-accent center" else "center", value);
    }
    fn toggle(s: *Canvas, x: i32, y: i32, on: bool) !void {
        try s.rect(x, y, 44, 24, 12, if (on) "accent" else "button");
        try s.out("<circle cx='{d}' cy='{d}' r='8' class='{s}'/>\n", .{ x + @as(i32, if (on) 31 else 13), y + 12, if (on) "on-accent" else "muted" });
    }
    fn disclosure(s: *Canvas, x: i32, y: i32, w: i32, title: []const u8, summary: []const u8) !void {
        try s.rect(x, y, w, 76, 16, "card");
        try s.text(x + 20, y + 29, "strong", title);
        try s.text(x + 20, y + 53, "muted small", summary);
        try s.text(x + w - 20, y + 40, "right", "›");
    }
    fn row(s: *Canvas, x: i32, y: i32, w: i32, name: []const u8, value: []const u8) !void {
        try s.text(x + 20, y + 28, "", name);
        try s.text(x + w - 20, y + 28, "right muted", value);
    }
    fn modes(s: *Canvas, x: i32, y: i32, w: i32, narrow: bool) !void {
        const names = [_][]const u8{ "CPU", "Automatic", "Selected GPU" };
        const subs = [_][]const u8{ "Use the processor", "GPU, otherwise CPU", "Choose a device" };
        const tw = if (narrow) w else @divTrunc(w - 20, 3);
        for (names, 0..) |name, i| {
            const n: i32 = @intCast(i);
            const tx = x + if (narrow) @as(i32, 0) else n * (tw + 10);
            const ty = y + if (narrow) n * 52 else @as(i32, 0);
            try s.rect(tx, ty, tw, if (narrow) 44 else 68, 12, if (i == 0) "selected" else "button");
            try s.text(tx + 12, ty + 27, "", if (i == 0) "●" else "○");
            try s.text(tx + 36, ty + 27, "strong", name);
            if (!narrow) try s.text(tx + 36, ty + 49, "small muted", subs[i]);
        }
    }
};
const View = enum { desktop, light, narrow, details, comparison, states };

fn overview(s: *Canvas, narrow: bool, x: i32, w: i32) !void {
    const y: i32 = if (narrow) 190 else 150;
    try s.rect(x, y, w, if (narrow) 150 else 108, 16, "card");
    try s.text(x + 20, y + 32, "section", "Launcher assistant");
    try s.toggle(x + w - 64, y + 20, true);
    try s.text(x + 20, y + 58, "small muted", if (narrow) "On in draft · Apply to enable" else "On in draft · Apply to enable · Open with Super + Space");
    try s.text(x + 20, y + 84, "small muted", if (narrow) "Answers run locally. Submitted questions" else "Answers run locally. Submitted questions go to your search engine; typing sends nothing.");
    if (narrow) try s.text(x + 20, y + 103, "small muted", "go to your engine; typing sends nothing.");
    try s.text(x + 20, y + (if (narrow) @as(i32, 128) else 0), if (narrow) "small muted" else "hidden", "Experimental · Answers can be wrong.");
    const my: i32 = if (narrow) 356 else 274;
    try s.rect(x, my, w, if (narrow) 202 else 174, 16, "card");
    try s.text(x + 20, my + 32, "section", "Model");
    if (!narrow) try s.text(x + w - 20, my + 32, "right small muted", "Downloaded · checked again before use");
    try s.rect(x + 20, my + 48, w - 40, 50, 10, "button");
    try s.text(x + 34, my + 79, "strong", if (narrow) "LFM2.5-1.2B-Instruct" else "LFM2.5-1.2B-Instruct  ·  Q4_K_M  ·  731 MB");
    try s.text(x + w - 34, my + 79, "right", "⌄");
    if (narrow) try s.text(x + 20, my + 121, "small muted", "Q4_K_M · 731 MB · Downloaded");
    const by = my + (if (narrow) @as(i32, 138) else 114);
    try s.button(x + 20, by, 154, "Verify model now", false);
    try s.button(x + 184, by, if (narrow) 154 else 152, "Model options  ⌄", false);
    if (!narrow) try s.text(x + w - 20, by + 25, "right small muted", "Selection never starts a download");
    const ry: i32 = if (narrow) 574 else 464;
    try s.rect(x, ry, w, if (narrow) 268 else 166, 16, "card");
    try s.text(x + 20, ry + 32, "section", "Runtime &amp; acceleration");
    try s.text(x + 20, ry + 57, "small muted", if (narrow) "System installation · Not checked" else "System installation · Not checked for this draft");
    try s.modes(x + 20, ry + 72, w - 40, narrow);
    if (narrow) {
        try s.text(x + 20, ry + 247, "small", "Runtime setup &amp; checks  ›");
        try s.disclosure(x, 858, w, "Search engines", "Bing · Default · No key needed");
        try s.disclosure(x, 950, w, "Compare models", "Choose models and run local tests");
    } else {
        try s.text(x + w - 20, ry + 32, "right small", "Runtime setup &amp; checks  ›");
        try s.disclosure(x, 646, w, "Search engines", "Bing · Default · No account or API key needed");
        try s.disclosure(x, 738, w, "Compare models", "Choose models, compare local performance and review saved results");
        try s.disclosure(x, 830, w, "Resources &amp; behavior", "Automatic model profile · Unload after 60 seconds · Read result pages on");
        try s.text(x + 4, 940, "small muted", "Experimental assistant · Check answers and their sources.");
        try s.text(x + 4, 962, "small muted", "Downloads, tests and key changes run only when you request them.");
    }
}

fn details(s: *Canvas, x: i32, w: i32) !void {
    try s.rect(x, 150, w, 332, 16, "card");
    try s.text(x + 20, 182, "section", "Runtime setup &amp; checks");
    try s.text(x + w - 20, 182, "right", "⌄");
    try s.row(x, 198, w, "Runtime source", "Custom executable   ⌄");
    try s.rect(x + 20, 244, w - 164, 42, 10, "button");
    try s.text(x + 34, 271, "muted", "/home/zoey/bin/llama-server");
    try s.button(x + w - 130, 244, 110, "Browse…", false);
    try s.button(x + 20, 300, 160, "Set up runtime…", false);
    try s.button(x + 190, 300, 182, "Discover devices now", false);
    try s.button(x + 382, 300, 218, "Check runtime &amp; model now", false);
    try s.text(x + 20, 367, "small muted", "Setup may install packages immediately; Apply saves only the runtime selection.");
    try s.text(x + 20, 391, "small muted", "Not checked for this draft · Checks run locally and do not send searches.");
    try s.row(x, 408, w, "GPU options", "Automatic backend · Automatic device   ›");
    try s.text(x + 20, 464, "small muted", "Device, fallback, layer and memory controls appear when relevant to the selected mode.");
    try s.rect(x, 498, w, 270, 16, "card");
    try s.text(x + 20, 530, "section", "Search engines");
    try s.text(x + w - 20, 530, "right", "⌄");
    try s.row(x, 546, w, "Edit engine", "Bing · Default   ⌄");
    try s.row(x, 588, w, "Safe search", "");
    try s.toggle(x + w - 64, 600, true);
    try s.text(x + 20, 651, "small muted", "Test sends “Pearl desktop” to Bing now. Changing settings does not send a request.");
    try s.button(x + 20, 670, 180, "Test connection now", false);
    try s.button(x + 210, 670, 160, "Add engine…", false);
    try s.button(x + 380, 670, 178, "Engine options  ⌄", false);
    try s.text(x + 20, 746, "small", "Search all enabled engines (maximum 3)");
    try s.toggle(x + w - 64, 730, false);
    try s.rect(x, 784, w, 206, 16, "card");
    try s.text(x + 20, 816, "section", "Resources &amp; behavior");
    try s.row(x, 832, w, "CPU threads / context / generation tokens", "Automatic / Model profile / Model profile  ›");
    try s.row(x, 877, w, "Unload model after idle", "−       60 seconds       +");
    try s.row(x, 922, w, "Read search result pages", "");
    try s.toggle(x + w - 64, 934, true);
    try s.text(x + 20, 979, "small muted", "Conversations stay in this session. Applying Off stops the assistant and clears them.");
}

fn comparison(s: *Canvas, x: i32, w: i32) !void {
    try s.text(x, 160, "small muted", "Assistant / Compare models · Expanded section · Illustrative results");
    try s.rect(x, 180, w, 252, 16, "card");
    try s.text(x + 20, 212, "section", "Choose models");
    try s.text(x + 20, 237, "small muted", "Uses local sample evidence. No searches or conversation history are used.");
    try s.row(x, 250, w, "☑  LFM2.5-1.2B-Instruct · Q4_K_M", "731 MB · Downloaded · License ↗");
    try s.row(x, 294, w, "☑  Qwen3-4B-Instruct-2507 · Q4_K_M", "2.50 GB · Downloaded · License ↗");
    try s.row(x, 338, w, "☐  LFM2.5-2.6B · Q4_K_M", "1.67 GB · Not installed · License ↗");
    try s.text(x + 20, 407, "small", "Other models (2)  ›");
    try s.text(x + w - 20, 407, "right small muted", "2 selected · No downloads needed");
    try s.rect(x, 448, w, 156, 16, "card");
    try s.row(x, 462, w, "Hardware / comparison depth", "CPU   ⌄        Quick · model profiles   ⌄");
    try s.text(x + 20, 519, "small muted", "Warm-up + 3 measured runs per fixture. Detailed comparisons take longer.");
    try s.button(x + 20, 540, 236, "Compare installed selections", false);
    try s.text(x + 276, 566, "small muted", "Starts immediately · You can cancel");
    try s.rect(x, 620, w, 350, 16, "card");
    try s.text(x + 20, 652, "section", "Saved results");
    try s.text(x + w - 20, 652, "right small", "Sort: Completion time  ⌄");
    try s.text(x + 20, 680, "small muted", "Example run · CPU · Same 4096-token context · Values are mock data");
    try s.text(x + 20, 716, "small muted", "MODEL / ACTUAL BACKEND");
    try s.text(x + 390, 716, "small muted", "COMPLETE ANSWER");
    try s.text(x + 640, 716, "small muted", "PEAK RAM / OUTCOME");
    try s.rect(x + 10, 731, w - 20, 40, 8, "selected");
    try s.row(x, 730, w, "●  LFM2.5-1.2B-Instruct · CPU", "");
    try s.text(x + 390, 758, "", "4.8 s · range 4.4–5.3 s");
    try s.text(x + 640, 758, "", "1.4 GiB · Completed");
    try s.row(x, 775, w, "○  Qwen3-4B-Instruct-2507 · CPU", "");
    try s.text(x + 390, 803, "", "8.9 s · range 8.3–9.6 s");
    try s.text(x + 640, 803, "", "3.6 GiB · Completed");
    try s.button(x + 20, 829, 138, "Show samples", false);
    try s.button(x + 168, 829, 198, "Use this configuration", false);
    try s.text(x + 386, 855, "small muted", "Updates the draft; Apply saves it");
    try s.text(x + 20, 901, "small muted", "Download size is separate from runtime RAM. Inspect samples before choosing.");
    try s.text(x + 20, 939, "small", "History  ⌄       Refresh       Export selected…       Delete selected…");
}

fn states(s: *Canvas, x: i32, w: i32) !void {
    try s.text(x, 158, "small muted", "Independent examples · Keep progress and recovery beside the action that started them");
    const cw = @divTrunc(w - 16, 2);
    const titles = [_][]const u8{ "Assistant is off", "Model not installed", "Downloading model", "Runtime check failed", "Connection needs a key", "Answer in progress" };
    const lines = [_][3][]const u8{
        .{ "Configure models and engines while off.", "Enable in the draft, then Apply &amp; save.", "Opening this page starts no work." },
        .{ "LFM2.5-1.2B-Instruct · 731 MB", "Download is immediate and independent", "of Apply / Discard. Selection is unchanged." },
        .{ "LFM2.5-1.2B-Instruct · 42%", "307 MB of 731 MB · Illustrative progress", "Cancel requests a stop; wait for cleanup." },
        .{ "Selected executable was not found.", "Choose another runtime or correct its path.", "Your draft settings have been kept." },
        .{ "Brave Search API · Key unavailable", "Unlock Secret Service or save a key now.", "Saving a key is separate from Apply." },
        .{ "Applying this change needs the answer to stop.", "Stop this answer and save your changes?", "Keep editing leaves the answer running." },
    };
    const actions = [_][]const u8{ "Review configuration", "Download 731 MB now", "Cancel download", "Retry check now", "Save key now", "Stop &amp; apply" };
    for (titles, 0..) |title, i| {
        const n: i32 = @intCast(i);
        const cx = x + @mod(n, 2) * (cw + 16);
        const cy = 180 + @divTrunc(n, 2) * 264;
        try s.rect(cx, cy, cw, 248, 16, "card");
        try s.text(cx + 20, cy + 34, "section", title);
        for (lines[i], 0..) |line, j| try s.text(cx + 20, cy + 72 + @as(i32, @intCast(j)) * 25, "small muted", line);
        if (i == 2) {
            try s.rect(cx + 20, cy + 142, cw - 40, 5, 2, "button");
            try s.rect(cx + 20, cy + 142, @divTrunc((cw - 40) * 42, 100), 5, 2, "accent");
        }
        try s.button(cx + 20, cy + 172, 204, actions[i], false);
        if (i == 3) try s.text(cx + 240, cy + 197, "small", "Details  ›");
        if (i == 5) try s.text(cx + 240, cy + 197, "small", "Keep editing");
    }
}

fn render(a: std.mem.Allocator, view: View) ![]const u8 {
    var s: Canvas = .{ .a = a };
    const light = view == .light;
    const narrow = view == .narrow;
    const width: i32 = if (narrow) 390 else 1200;
    const height: i32 = 1120;
    try s.out("<svg xmlns='http://www.w3.org/2000/svg' width='{d}' height='{d}' viewBox='0 0 {d} {d}' role='img' aria-labelledby='title desc'><title id='title'>Assistant settings layout — {s}</title><desc id='desc'>Static design proposal using Pearl settings cards, summary disclosures, native control styling and a persistent shared draft footer. Sample states and data are illustrative.</desc>\n", .{ width, height, width, height, @tagName(view) });
    try s.out("<style>text{{font-family:Inter,'DejaVu Sans',sans-serif;font-size:14px;fill:{s}}}.bg{{fill:{s}}}.sidebar{{fill:{s}}}.card{{fill:{s}}}.button{{fill:{s};stroke:{s}}}.selected{{fill:{s};stroke:{s}}}.accent{{fill:{s}}}.on-accent{{fill:{s}}}.muted{{fill:{s}}}.strong{{font-weight:600}}.small{{font-size:12px}}.tiny{{font-size:10px;letter-spacing:1.4px}}.section{{font-size:17px;font-weight:600}}.heading{{font-size:30px;font-weight:500;letter-spacing:-.6px}}.center{{text-anchor:middle}}.right{{text-anchor:end}}.line{{stroke:{s};fill:none}}.hidden{{display:none}}</style>\n", .{
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
            if (i == 10) try s.rect(12, ny - 25, 196, 42, 11, "selected");
            try s.text(24, ny, if (group) "tiny muted" else "", name);
            ny += if (group) 34 else 44;
        }
    } else try s.button(16, 65, 106, "☰  Sections", false);
    const x: i32 = if (narrow) 16 else 250;
    const w: i32 = if (narrow) 358 else 920;
    const hy: i32 = if (narrow) 141 else 101;
    try s.text(x, hy, "heading", "Assistant");
    try s.text(x, hy + 26, "muted", if (narrow) "Local answers, your search engines." else "Local answers with your chosen search engines.");
    switch (view) {
        .desktop, .light, .narrow => try overview(&s, narrow, x, w),
        .details => try details(&s, x, w),
        .comparison => try comparison(&s, x, w),
        .states => try states(&s, x, w),
    }
    const fy: i32 = 1042;
    try s.rect(if (narrow) 0 else 220, fy, width - (if (narrow) @as(i32, 0) else 220), 78, 0, "bg");
    try s.out("<path d='M{d} {d}H{d}' class='line'/>\n", .{ if (narrow) @as(i32, 0) else 220, fy, width });
    try s.text(x, fy + (if (narrow) @as(i32, 22) else 30), "small muted", if (narrow) "Unsaved Pearl preferences" else "Unsaved Pearl preferences · shared across tabs");
    if (!narrow) try s.text(x, fy + 51, "small muted", "Downloads and tests are separate immediate actions.");
    try s.button(width - 260, fy + (if (narrow) @as(i32, 32) else 19), 92, "Discard", false);
    try s.button(width - 156, fy + (if (narrow) @as(i32, 32) else 19), 140, "Apply &amp; save", true);
    if (view != .states) try s.rect(width - 7, if (view == .details or view == .comparison) 410 else 190, 3, 180, 2, "muted");
    try s.out("</svg>\n", .{});
    return s.data.items;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    for (std.enums.values(View)) |view| {
        const path = try std.fmt.allocPrint(a, "docs/mockups/assistant-layout/{s}.svg", .{@tagName(view)});
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, try render(a, view));
    }
}
