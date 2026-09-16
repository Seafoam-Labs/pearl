# Qt application appearance: QtEngine + Darkly

Pearl uses **QtEngine** for Qt 5/6 platform integration and **Darkly's application
style** to draw widgets. KWin decorations are excluded from the supplied Darkly
package. Open **Pearl Settings → Appearance → Qt applications · QtEngine + Darkly**
and enable management with **Apply & save**. Management is off by default and
participates in the shared draft; previews do not write external settings.

## Install and activate

Build the updated Pearl and its separate runtime probes:

```sh
zig build -Doptimize=ReleaseSafe -Dqt-themes=true
bash scripts/repair-darkly-deps.sh
```

The Shelly setup script upgrades standard packages, installs `qtengine`, builds
and installs the pinned [pearl-darkly-style package](../packaging/arch-darkly-style/PKGBUILD),
and verifies actual plugin loading. It retains Shelly's normal prompts. Unowned
Darkly application plugins and old KWin decoration files are backed up beneath
`/var/backups/pearl-darkly-kwin.*` before replacement. If setup fails, it prints the
backup/build locations; no Pearl appearance preferences are changed by setup.
Existing package-owned Darkly variants are handled through package conflicts.

The application-only package contains the Qt 5/6 style plugins and license. It
sets `WITH_DECORATIONS=OFF`, omits KCM configuration applications and Plasma assets,
and disables the optional legacy Qt 5 Kirigami hooks while retaining the Qt Quick
Widgets library used by the style. It does not need the removed `kirigami2`
package. Qt 6 Kirigami and shared KDE Frameworks libraries remain dependencies;
`kwindowsystem` is a library used by applications, not the KWin compositor.

Stable and Git Pearl PKGBUILDs list `qtengine` and `pearl-darkly-style` as optional
dependencies. The second package is supplied in this repository; installing the
upstream full `darkly` package may include additional components. qt5ct/qt6ct are
no longer Pearl runtime dependencies. Optional Qt probes link Qt; the Pearl shell
and Settings remain Zig/GTK applications. The default source build without
`-Dqt-themes=true` has no Qt build dependency. Probes are installed in
`/usr/lib/pearl`, or found beside the development binaries in `zig-out/bin`.

After installation, use **Retry saved Qt settings** in Appearance. Sign out and
back in when the environment status requests it. The installed authenticated
Pearl/Aqueous login wrapper and UWSM `env-aqueous.d/60-pearl-qt.sh` set
`QT_QPA_PLATFORMTHEME=qtengine` before applications start. Custom direct session
entrypoints must source `/usr/lib/pearl/qt-environment.sh` before starting the
compositor/apps. Already-running launchers and D-Bus services retain their
original environment. Fresh physical-login propagation remains a manual check.

The startup hook reads a fixed marker as data and skips `AQUEOUS_NESTED=1`.
It preserves an explicit competing platform plugin. `QT_STYLE_OVERRIDE` and a
`QTENGINE_CONFIG` pointing elsewhere are reported as conflicts; Pearl does not
silently unset them. Old qtct markers remain supported solely until migration
can complete. No global Flatpak overrides are installed.

## Appearance and runtime checks

QtEngine uses **one shared configuration for both Qt versions**. The **Check Qt 5**
and **Check Qt 6** switches select which installed runtimes Pearl verifies; they
cannot give the two versions different configurations or exclude an individual
version's apps from the session environment. Both checks off releases management.
A missing runtime is reported independently, while an available runtime can use
the shared configuration. Probes require the actual Darkly style, QtEngine
platform plugin, its proxy style plugin and the `qtengine` selection key to load.
A broken plugin cannot crash the Pearl process.

- **Follow Pearl** uses committed static or generated Material colors. Seed and
  wallpaper changes reuse the existing generation lifecycle. GTK mode uses a
  labelled static dark/light fallback; it does not extract arbitrary GTK CSS.
- **Static dark/light** fixes Qt to Pearl's selected static palette. The generated
  KDE scheme contains Window, View, Button, Selection, Tooltip, Complementary and
  Header color sets. KDE derives palette groups, shades and disabled effects.
- **Synchronize font** maps Pearl's logical pixel size to QtEngine's integer
  point size at 96 DPI, rounded to the nearest point. For example 14 logical
  pixels maps to 11 points; exact pixel equivalence is not possible for every
  size. Qt applies display scaling. An empty Pearl family preserves QtEngine's
  existing family; font weight and fixed-width font remain unmanaged.
- An empty icon theme leaves the existing value unmanaged. Explicit themes must
  be available to the runtime probe.
- Darkly corner radius, reduced-motion synchronization and optional compact
  density remain available. Radius 0 in the UI releases ownership of that field.
  Selected animation keys and four optional KDE focus/hover/negative/background
  colors follow Pearl. These are application colors, not KWin decoration settings.

QtEngine's file watcher delivered live palette updates to running Qt 5 and Qt 6
Widgets fixtures on a private D-Bus session. The base widget style, fonts, icons,
geometry and individual application overrides may require an app restart;
Settings conservatively reports that some applications need restarting. D-Bus
availability matters for QtEngine's live updates.

## Ownership, migration and restoration

Changes affect applications sharing the account's XDG configuration directory,
including apps launched outside Pearl. Committed preferences from the active,
unlocked Aqueous backend trigger worker reconciliation. A Qt integration failure
is reported separately and does not undo a successful Pearl preference commit.
`pearlctl preferences status` and Settings report desired/applied revisions and
Qt 5, Qt 6, QtEngine, Darkly, KDE and environment status.

Paths below are relative to `$XDG_CONFIG_HOME` (normally `~/.config`):

| File | Managed content |
| --- | --- |
| `qtengine/config.json` | `theme.style`, `theme.colorScheme`, optional `theme.iconTheme`, `theme.font.size`, explicit `theme.font.family` |
| `darklyrc` | Selected application radius, density and animation keys |
| `kdeglobals` | Optional Colors:View focus/hover/negative keys and Colors:Window alternate background |
| `pearl/qt/scheme-<hash>.colors` | Immutable shared KDE color scheme |
| `pearl/qt/engine.json` | Per-leaf QtEngine ownership and interrupted-write recovery |
| `pearl/qt/{darkly,kde}.json` | Per-key INI ownership/recovery |
| `pearl/qt/{qt5,qt6}.json` | Retained legacy qtct recovery records, when present |
| `pearl/qt/writer.lock`, `session.conf` | Single-writer lease and fixed login marker |

The new adapter never enables management through qtct. After a working QtEngine
configuration is published, it conditionally restores old qtct keys from Pearl's
legacy ledgers. User edits survive and report `restore_incomplete`; unrelated
qtct files are untouched. If both runtime probes fail during migration, the old
marker and configuration are retained. Disabling also attempts legacy cleanup.

QtEngine edits preserve unrelated JSON values, including `misc`, fixed-width
fonts and font weight; changed documents are reformatted. Existing INI comments
and unrelated keys are preserved. Duplicate JSON keys, invalid parent types,
ambiguous INI, excessive input and redirected write paths fail safely. Each
managed target has a bounded write-ahead ledger and compare-before-replace
atomic writes. Interrupted writes are resolved against observed values.
Unchanged Apply operations avoid rewrites. Unreferenced generated palettes are
collected only when configurations and recovery references can be read safely.

**Review external Qt changes** shows current, previous Pearl and original values.
**Replace reviewed values with saved Qt settings** requires that exact review to
remain current. Ordinary retry does not overwrite a conflicting external edit.
Disable and Apply to restore original values only where the current value still
matches Pearl's last write. Introduced leaves are removed; empty objects,
sections or files may remain. Keep ownership records until restoration completes.

Before downgrade/removal, disable management, resolve restoration conflicts and
sign out. Older pre-Qt Pearl versions reject the `qt` preference field; remove it
only after restoring through the current version. Going back to the earlier
qtct implementation also requires restoring this QtEngine configuration first.
Package removal does not erase user recovery data or the unowned-file backups.

## Verified scope

| Consumer | Classification |
| --- | --- |
| Native Qt 5.15.19 / Qt 6.11.2 Widgets | Verified with QtEngine commit `073987f0120ac77a92fb9f0c0877aa7f1f04d3bf` and the supplied application-only Darkly build |
| Qt 6 Quick Controls / Kirigami | Partial: Fusion QML fixtures inherit Pearl's platform palette; Darkly remains a Widgets style |
| Dolphin / Kate | Unverified: not installed in the test environment |
| KDE-runtime Flatpak | Unsupported pending runtime-specific extension and activation tests |
| Physical direct/UWSM login, GPU presentation and screen-reader speech | Manual acceptance pending |

Darkly is pinned to source version 0.5.39, commit
`65f6fa62675e3c30986f8fc8e4fdbba053096491`, with the repository's application-style
build patch. The tested plugin hashes and staging evidence are recorded in
[QtEngine evidence](../artifacts/qtengine/README.md). Builds and automated tests
were private; the user's installed plugins/configuration were not changed.

[QtEngine upstream](https://github.com/kossLAN/qtengine) documents its shared JSON
configuration and platform selection. [Darkly upstream](https://github.com/Bali10050/Darkly)
provides the application style; the local recipe excludes its KWin decorations.
