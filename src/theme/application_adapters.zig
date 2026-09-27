//! Built-in application metadata. Templates never choose destinations or commands.
const std = @import("std");
const glib = @import("glib2");
const profiles = @import("matugen_profiles.zig");
pub const Application = profiles.Application;
pub const Group = enum { toolkits, terminals, editors, browsers, chat, other };
pub fn group(app: Application) Group {
    return switch (app) {
        .gtk, .qt5ct, .qt6ct, .kcolorscheme => .toolkits,
        .ghostty, .kitty, .foot, .alacritty, .wezterm => .terminals,
        .zed, .nvim, .vscode, .emacs => .editors,
        .firefox, .zenbrowser, .pywalfox => .browsers,
        .equibop, .vesktop, .vencord, .fluxer => .chat,
        else => .other,
    };
}
pub fn commands(app: Application) []const [:0]const u8 {
    return switch (app) {
        .zed => &.{ "zed", "zeditor", "zedit" },
        .gtk, .kcolorscheme => &.{},
        .qt5ct => &.{"qt5ct"},
        .qt6ct => &.{"qt6ct"},
        .ghostty => &.{"ghostty"},
        .kitty => &.{"kitty"},
        .foot => &.{"foot"},
        .alacritty => &.{"alacritty"},
        .wezterm => &.{"wezterm"},
        .nvim => &.{"nvim"},
        .vscode => &.{ "code", "codium", "cursor", "windsurf", "code-insiders" },
        .emacs => &.{"emacs"},
        .firefox => &.{"firefox"},
        .zenbrowser => &.{ "zen", "zen-browser", "zen-beta", "zen-twilight" },
        .pywalfox => &.{"pywalfox"},
        .equibop => &.{"equibop"},
        .vesktop => &.{"vesktop"},
        .vencord => &.{ "discord", "Discord", "discord-canary", "DiscordCanary" },
        .starship => &.{"starship"},
        .steam => &.{"steam"},
        .fluxer => &.{"fluxer"},
        .fcitx5 => &.{"fcitx5"},
    };
}
pub fn flatpaks(app: Application) []const []const u8 {
    return switch (app) {
        .vesktop => &.{"dev.vencord.Vesktop"},
        .vencord => &.{ "com.discordapp.Discord", "com.discordapp.DiscordCanary" },
        else => &.{},
    };
}
pub fn detected(app: Application) bool {
    if (commands(app).len == 0) return true;
    for (commands(app)) |command| if (glib.findProgramInPath(command)) |path| {
        glib.free(path);
        return true;
    };
    for (flatpaks(app)) |id| {
        var buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buffer, "{s}/.var/app/{s}/config", .{ std.mem.span(glib.getHomeDir()), id }) catch continue;
        if (glib.fileTest(path, .{ .is_dir = true }) != 0) return true;
    }
    return false;
}
pub fn managed(app: Application) bool {
    return switch (app) {
        .fluxer, .steam, .firefox, .zenbrowser => false,
        else => true,
    };
}
pub fn root(a: std.mem.Allocator, config: []const u8, app: Application) ![]const u8 {
    if (app == .equibop) if (glib.getenv("EQUICORD_USER_DATA_DIR")) |value| return std.fmt.allocPrint(a, "{s}/themes", .{std.mem.span(value)});
    if (app == .starship and glib.getenv("STARSHIP_CONFIG") != null) return error.CustomStarshipConfigRequiresManualSetup;
    if (app == .emacs) {
        const xdg = try std.fmt.allocPrintSentinel(a, "{s}/emacs", .{config}, 0);
        const legacy = try std.fmt.allocPrintSentinel(a, "{s}/.emacs.d", .{std.mem.span(glib.getHomeDir())}, 0);
        if (glib.fileTest(xdg, .{ .is_dir = true }) == 0 and glib.fileTest(legacy, .{ .is_dir = true }) != 0) return std.fmt.allocPrint(a, "{s}/themes", .{legacy});
    }
    const base = switch (app) {
        .fcitx5, .kcolorscheme, .vscode => std.mem.span(glib.getUserDataDir()),
        .pywalfox => std.mem.span(glib.getUserCacheDir()),
        else => config,
    };
    const suffix: []const u8 = switch (app) {
        .zed => "zed/themes",
        .equibop => "equibop/themes",
        .vesktop => "vesktop/themes",
        .vencord => "Vencord/themes",
        .gtk, .starship => "",
        .qt5ct => "qt5ct/colors",
        .qt6ct => "qt6ct/colors",
        .kcolorscheme => "color-schemes",
        .ghostty => "ghostty/themes",
        .kitty => "kitty",
        .foot => "foot",
        .alacritty => "alacritty",
        .wezterm => "wezterm/colors",
        .nvim => "nvim",
        .emacs => "emacs/themes",
        .fcitx5 => "fcitx5/themes/pearl-material",
        .pywalfox => "wal",
        .vscode => "pearl/vscode",
        else => return error.ManualProfileActivation,
    };
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, suffix });
}
pub fn name(a: std.mem.Allocator, app: Application, id: []const u8, output: []const u8, index: usize) ![]const u8 {
    return switch (app) {
        .gtk => "gtk-3.0/pearl-material.css",
        .ghostty => "pearl-material",
        .kitty => if (index == 0) "pearl-material.conf" else "pearl-material-tabs.conf",
        .foot => "pearl-material.ini",
        .alacritty, .wezterm => "pearl-material.toml",
        .qt5ct, .qt6ct => "pearl-material.conf",
        .kcolorscheme => switch (index) {
            0 => "pearl-material.colors",
            1 => "pearl-material-dark.colors",
            else => "pearl-material-light.colors",
        },
        .nvim => if (index == 0) "colors/pearl-material.lua" else "lua/lualine/themes/pearl-material.lua",
        .emacs => "pearl-material-theme.el",
        .fcitx5 => switch (index) {
            0 => "theme.conf",
            1 => "panel.svg",
            else => "highlight.svg",
        },
        .pywalfox => "colors.json",
        .vscode => "pearl-material.vsix",
        else => std.fmt.allocPrint(a, "pearl-{s}-{s}", .{ id, output }),
    };
}
pub fn allowed(app: Application, path: []const u8) bool {
    if (path.len == 0 or path.len > 240) return false;
    for (path) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '/')) return false;
    if (std.mem.indexOf(u8, path, "..") != null or std.mem.startsWith(u8, path, "/")) return false;
    return switch (app) {
        .gtk => std.mem.eql(u8, path, "gtk-3.0/pearl-material.css") or std.mem.eql(u8, path, "gtk-4.0/pearl-material.css") or std.mem.eql(u8, path, "gtk-3.0/gtk.css") or std.mem.eql(u8, path, "gtk-4.0/gtk.css"),
        .nvim => std.mem.eql(u8, path, "colors/pearl-material.lua") or std.mem.eql(u8, path, "lua/lualine/themes/pearl-material.lua"),
        .fcitx5 => std.mem.eql(u8, path, "theme.conf") or std.mem.eql(u8, path, "panel.svg") or std.mem.eql(u8, path, "highlight.svg"),
        .pywalfox => std.mem.eql(u8, path, "colors.json"),
        .starship => std.mem.eql(u8, path, "starship.toml"),
        else => std.mem.startsWith(u8, path, "pearl-") and std.mem.indexOfScalar(u8, path, '/') == null,
    };
}
pub fn instructions(app: Application) []const u8 {
    return switch (app) {
        .gtk => "GTK 3/4 imports use Pearl-owned colors. GTK 3 needs a compatible theme such as adw-gtk3. Restart applications that cache CSS. Application-specific hard-coded colors may remain unchanged.",
        .qt5ct, .qt6ct => "Choose pearl-material in the qtct Appearance color scheme list. This exports colors only; Pearl's managed Qt applications use QtEngine + Darkly. Do not enable competing platform plugins.",
        .kcolorscheme => "Choose the Pearl Material .colors scheme in a compatible KDE application. For Qt session activation, use Appearance → Qt applications · QtEngine + Darkly; its Follow Pearl palette follows the shell, independently of application colors.",
        .ghostty => "Set theme = pearl-material in the Ghostty configuration, then reload the configuration.",
        .kitty => "Add include pearl-material.conf and include pearl-material-tabs.conf to kitty.conf, then reload the configuration.",
        .foot => "Add include=~/.config/foot/pearl-material.ini under [main] in foot.ini (adjust for XDG_CONFIG_HOME), then restart Foot.",
        .alacritty => "Add the full path to pearl-material.toml to general.import in alacritty.toml.",
        .wezterm => "Set config.color_scheme = 'pearl-material' in wezterm.lua, then reload.",
        .nvim => "Run :colorscheme pearl-material or set it in init.lua. For lualine, set options.theme = 'pearl-material'. No base46 or DMS plugin is required.",
        .emacs => "Add the generated theme directory to custom-theme-load-path, then (load-theme 'pearl-material t). For a custom Emacs root, use the generated path explicitly.",
        .vscode => "Install pearl-material.vsix from the output path with Extensions: Install from VSIX, then choose Pearl Material Dark/Light. Supported editor CLIs: code, codium, cursor, windsurf, code-insiders. Reinstall the generated VSIX after palette changes; Pearl does not edit installed extensions.",
        .zed => "Select Pearl Material Dark or Pearl Material Light in Zed's theme selector.",
        .firefox, .zenbrowser => "Open about:profiles and choose the intended profile. Enable toolkit.legacyUserProfileCustomizations.stylesheets, import the generated CSS from chrome/userChrome.css using its absolute file URL, and restart the browser. Flatpak Zen uses app.zen_browser.zen; choose a stylesheet location accessible inside its sandbox.",
        .pywalfox => "Install/enable the Pywalfox browser extension and native helper. Pearl manages XDG_CACHE_HOME/wal/colors.json only if unowned or unchanged. Run pywalfox update after applying new colors; conflicting wal generators must be disabled separately.",
        .vesktop => "Enable the Pearl CSS theme in Vesktop. For Flatpak dev.vencord.Vesktop, Pearl also updates its existing sandbox config/vesktop/themes directory; activate the theme there.",
        .vencord => "Enable the Pearl CSS theme in Vencord. For Flatpak com.discordapp.Discord or com.discordapp.DiscordCanary, Pearl also updates the existing sandbox config/Vencord/themes directory; activate the theme there.",
        .equibop => "Enable the Pearl Material CSS in Equibop's theme settings.",
        .fcitx5 => "In Fcitx5 Configuration → Addons → Classic User Interface, choose pearl-material and disable Follow system accent color if it overrides the palette. Reload Fcitx5 after updates.",
        .starship => "Review and install the generated prompt configuration below before Pearl manages starship.toml. Custom STARSHIP_CONFIG paths require manual setup.",
        .fluxer => "Import the generated CSS in Fluxer's custom theme settings. This profile supports dark mode.",
        .steam => "Use the generated CSS with AdwSteamGtk. Run your installed theme tool to activate updates. This profile supports dark mode.",
    };
}
