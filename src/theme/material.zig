// Generated asset index; templates and manifests remain the source of truth.
const std = @import("std");
const profiles = @import("matugen_profiles.zig");
const model = @import("package_model.zig");
const pkg = @import("package.zig");
pub const revision: u32 = 1;
pub const palette = @embedFile("material/palette.json");
pub fn descriptor(a: std.mem.Allocator, app: profiles.Application) !profiles.Descriptor {
    return model.parse(profiles.Descriptor, a, switch (app) {
        .zed => @embedFile("material/pearl.material.zed/profile.json"),
        .equibop => @embedFile("material/pearl.material.equibop/profile.json"),
        .fluxer => @embedFile("material/pearl.material.fluxer/profile.json"),
        .starship => @embedFile("material/pearl.material.starship/profile.json"),
        .steam => @embedFile("material/pearl.material.steam/profile.json"),
        .gtk => @embedFile("material/pearl.material.gtk/profile.json"),
        .qt5ct => @embedFile("material/pearl.material.qt5ct/profile.json"),
        .qt6ct => @embedFile("material/pearl.material.qt6ct/profile.json"),
        .kcolorscheme => @embedFile("material/pearl.material.kcolorscheme/profile.json"),
        .ghostty => @embedFile("material/pearl.material.ghostty/profile.json"),
        .kitty => @embedFile("material/pearl.material.kitty/profile.json"),
        .foot => @embedFile("material/pearl.material.foot/profile.json"),
        .alacritty => @embedFile("material/pearl.material.alacritty/profile.json"),
        .wezterm => @embedFile("material/pearl.material.wezterm/profile.json"),
        .nvim => @embedFile("material/pearl.material.nvim/profile.json"),
        .vscode => @embedFile("material/pearl.material.vscode/profile.json"),
        .emacs => @embedFile("material/pearl.material.emacs/profile.json"),
        .firefox => @embedFile("material/pearl.material.firefox/profile.json"),
        .zenbrowser => @embedFile("material/pearl.material.zenbrowser/profile.json"),
        .pywalfox => @embedFile("material/pearl.material.pywalfox/profile.json"),
        .vesktop => @embedFile("material/pearl.material.vesktop/profile.json"),
        .vencord => @embedFile("material/pearl.material.vencord/profile.json"),
        .fcitx5 => @embedFile("material/pearl.material.fcitx5/profile.json"),
    }, 16384);
}
pub fn files(app: profiles.Application) []const pkg.File {
    return switch (app) {
        .zed => &.{
            .{ .path = "pearl-zed.json", .bytes = @embedFile("material/pearl.material.zed/pearl-zed.json") },
        },
        .equibop => &.{
            .{ .path = "vesktop.css", .bytes = @embedFile("material/pearl.material.equibop/vesktop.css") },
        },
        .fluxer => &.{
            .{ .path = "theme.css", .bytes = @embedFile("material/pearl.material.fluxer/theme.css") },
        },
        .starship => &.{
            .{ .path = "prompt.toml", .bytes = @embedFile("material/pearl.material.starship/prompt.toml") },
        },
        .steam => &.{
            .{ .path = "theme.css", .bytes = @embedFile("material/pearl.material.steam/theme.css") },
        },
        .gtk => &.{
            .{ .path = "gtk-colors.css", .bytes = @embedFile("material/pearl.material.gtk/gtk-colors.css") },
        },
        .qt5ct => &.{
            .{ .path = "qtct-colors.conf", .bytes = @embedFile("material/pearl.material.qt5ct/qtct-colors.conf") },
        },
        .qt6ct => &.{
            .{ .path = "qtct-colors.conf", .bytes = @embedFile("material/pearl.material.qt6ct/qtct-colors.conf") },
        },
        .kcolorscheme => &.{
            .{ .path = "kcolorscheme.colors", .bytes = @embedFile("material/pearl.material.kcolorscheme/kcolorscheme.colors") },
            .{ .path = "dark-kcolorscheme.colors", .bytes = @embedFile("material/pearl.material.kcolorscheme/dark-kcolorscheme.colors") },
            .{ .path = "light-kcolorscheme.colors", .bytes = @embedFile("material/pearl.material.kcolorscheme/light-kcolorscheme.colors") },
        },
        .ghostty => &.{
            .{ .path = "ghostty.conf", .bytes = @embedFile("material/pearl.material.ghostty/ghostty.conf") },
        },
        .kitty => &.{
            .{ .path = "kitty.conf", .bytes = @embedFile("material/pearl.material.kitty/kitty.conf") },
            .{ .path = "kitty-tabs.conf", .bytes = @embedFile("material/pearl.material.kitty/kitty-tabs.conf") },
        },
        .foot => &.{
            .{ .path = "foot.ini", .bytes = @embedFile("material/pearl.material.foot/foot.ini") },
        },
        .alacritty => &.{
            .{ .path = "alacritty.toml", .bytes = @embedFile("material/pearl.material.alacritty/alacritty.toml") },
        },
        .wezterm => &.{
            .{ .path = "wezterm.toml", .bytes = @embedFile("material/pearl.material.wezterm/wezterm.toml") },
        },
        .nvim => &.{
            .{ .path = "colors.lua", .bytes = @embedFile("material/pearl.material.nvim/colors.lua") },
            .{ .path = "lualine.lua", .bytes = @embedFile("material/pearl.material.nvim/lualine.lua") },
        },
        .vscode => &.{
            .{ .path = "vscode-color-theme-dark.json", .bytes = @embedFile("material/pearl.material.vscode/vscode-color-theme-dark.json") },
            .{ .path = "vscode-color-theme-light.json", .bytes = @embedFile("material/pearl.material.vscode/vscode-color-theme-light.json") },
            .{ .path = "package.json", .bytes = @embedFile("material/pearl.material.vscode/package.json") },
        },
        .emacs => &.{
            .{ .path = "pearl-emacs.el", .bytes = @embedFile("material/pearl.material.emacs/pearl-emacs.el") },
        },
        .firefox => &.{
            .{ .path = "firefox-userchrome.css", .bytes = @embedFile("material/pearl.material.firefox/firefox-userchrome.css") },
        },
        .zenbrowser => &.{
            .{ .path = "zen-userchrome.css", .bytes = @embedFile("material/pearl.material.zenbrowser/zen-userchrome.css") },
        },
        .pywalfox => &.{
            .{ .path = "pywalfox-colors.json", .bytes = @embedFile("material/pearl.material.pywalfox/pywalfox-colors.json") },
        },
        .vesktop => &.{
            .{ .path = "vesktop.css", .bytes = @embedFile("material/pearl.material.vesktop/vesktop.css") },
        },
        .vencord => &.{
            .{ .path = "vesktop.css", .bytes = @embedFile("material/pearl.material.vencord/vesktop.css") },
        },
        .fcitx5 => &.{
            .{ .path = "theme.conf", .bytes = @embedFile("material/pearl.material.fcitx5/theme.conf") },
            .{ .path = "panel.svg", .bytes = @embedFile("material/pearl.material.fcitx5/panel.svg") },
            .{ .path = "highlight.svg", .bytes = @embedFile("material/pearl.material.fcitx5/highlight.svg") },
        },
    };
}

test "static Material render data exactly projects both built-in shell palettes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try @import("render_data.zig").validate(arena.allocator(), palette, "dark", @import("theme.zig").dark);
    try @import("render_data.zig").validate(arena.allocator(), palette, "light", @import("theme.zig").light);
}
