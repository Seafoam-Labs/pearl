# Base Material application themes

Open **Settings → Appearance → Application themes**, choose **Use Material
defaults**, then **Apply & save**. First enablement also adopts these defaults.
Static Material dark/light themes supply complete fixed colors. Dynamic themes
reuse Pearl's seed or wallpaper palette; independent application colors remain
available. Matugen 4.x renders application templates; the static Pearl shell
continues working without it.

Management remains disabled by default. Existing enabled configurations retain
legacy assignments until **Use Material defaults** is applied. Explicit profile
choices and Off always take precedence. A community theme supplies its own
assignments; GTK shell mode has none. Choosing widget styling alone does not
replace Material assignments. qt5ct and qt6ct exports require **Choose profile**.

The built-in catalog has 23 targets:

| Group | Targets |
| --- | --- |
| Toolkits | GTK 3/4, qt5ct, qt6ct, KDE color schemes |
| Terminals | Ghostty, Kitty (including tabs), Foot, Alacritty, WezTerm |
| Editors | Zed, Neovim and lualine, VS Code family, Emacs |
| Browsers | Firefox, Zen Browser, Pywalfox |
| Chat | Equibop, Vesktop, Vencord, Fluxer |
| Other | Fcitx5, Starship, Steam |

QtEngine + Darkly uses the existing **Qt applications** controls on the same page.
Its Follow Pearl choice follows the shell's colors; independent Matugen
application colors do not implicitly change Qt. Niri, Hyprland, MangoWC and dgop
are excluded.

## Activation and updates

Each row shows the effective profile, origin, command detection, status, output
location and setup instructions. Detection is informational: Pearl can prepare
files before an application is installed. Generation/installation is distinct
from activation in a running application.

- GTK gets a scoped import in each `gtk-3.0/gtk.css` and `gtk-4.0/gtk.css`,
  retaining prior contents. GTK 3 needs compatible theme styling such as
  adw-gtk3. Applications that cache CSS may need restarting; hard-coded app
  colors are outside the palette's control.
- Terminals use Pearl-named theme/include files. Follow the row's configuration
  instructions once, then use the application's supported reload mechanism.
- Neovim uses `colorscheme pearl-material`; lualine uses the same theme name.
  No DMS or base46 plugin is needed. Emacs uses the XDG root or an existing
  legacy `~/.emacs.d` root; custom roots can load the reported path explicitly.
- Zed and chat clients need theme selection inside the application. Existing
  Vesktop and Discord/Discord Canary Flatpak sandboxes receive separately
  journaled CSS files. Pearl does not install clients or change sandbox permissions.
- Firefox and Zen provide CSS for an explicitly chosen browser profile. Use the
  row's chrome import instructions and enable the browser prerequisite. Pearl
  never guesses which browser profile to edit. Flatpak Zen requires an import
  location visible inside its sandbox.
- VS Code, VSCodium, Cursor, Windsurf and VS Code Insiders can install the generated
  `pearl-material.vsix` through **Install from VSIX**. Reinstall it after palette
  updates. Pearl generates a complete local extension without marketplace access;
  it does not rewrite installed extension directories.
- Fcitx5 installs its theme and panel/highlight SVG assets under XDG data. Select
  `pearl-material` in Classic User Interface and reload Fcitx5 after changes.
- Pywalfox uses `$XDG_CACHE_HOME/wal/colors.json`. The **Refresh Pywalfox from
  committed colors** button invokes only `pywalfox update`, with cancellation
  and a ten-second deadline. Install/enable its browser extension and helper
  separately. A successful refresh command does not prove browser activation.
- Starship retains the reviewed full-configuration installation flow. Fluxer
  and Steam retain their existing setup requirements and currently support dark
  mode only. Light mode reports that restriction and retains the previous output.

## Ownership and recovery

Changes apply only after commit. Preview, opening Settings and Discard do not
write application files. The renderer uses private configuration and never runs
contributed hooks or the user's global Matugen configuration. Template bytes and
fixed color input are retained in committed snapshots; **Use current profile
versions on Apply** explicitly adopts updated assets.

Off restores only unchanged Pearl-owned files, including original GTK CSS.
User edits cause a per-target conflict and are retained. Shared wal files owned
by another tool are not overwritten. A destination-root change is reported
instead of applying an old journal to a different directory. Generated previews
remain under `$XDG_CONFIG_HOME/pearl/matugen/outputs`; files installed in native
application directories are tracked by ownership journals.

Static palette data and assets are embedded, with reviewable copies and notices
under `share/pearl/material`. See [attribution](../src/theme/material/ATTRIBUTION.md)
and [verification evidence](../artifacts/base-material-matugen/README.md).
