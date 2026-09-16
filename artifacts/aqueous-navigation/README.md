# Aqueous sublist navigation review

Implemented September 16, 2026, from the
[navigation plan](../../docs/AQUEOUS_SETTINGS_NAVIGATION_PLAN.md).

The standalone Settings window now shows seven indented destinations beneath
Aqueous. The sidebar and narrow Sections popover share the same targets and
selection behavior. The header identifies the selected section; the dropdown
has been removed. Internal navigation transfers drafts and remembers each
section's scroll position and valid focus. Rebuilding editor controls clears
stale focus references, and explicit external links start at the heading.

## Visual evidence

- [Wide, dark](presentation/session/dark-aqueous.png)
- [Wide, light](presentation/session/light-aqueous.png)
- [Native GTK](presentation/session/native-aqueous.png)
- [Narrow sublist](presentation/session/narrow-dark-aqueous-sublist.png)
- [Narrow native GTK sublist](presentation/session/narrow-native-aqueous-sublist.png)
- [Large-text sublist](presentation/session/large-text-aqueous-sublist.png)

The selected destination scrolls into view after GTK allocates the navigation.
Other entries remain reachable through its independent scrollbar. Child rows
have Aqueous-qualified accessible names and at least 44-pixel widget targets;
the parent exposes expanded state. Selection and keyboard focus are distinct.

## Automated validation

Commands used `ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig-global`. Session tests ran
with permission to create private D-Bus and Wayland sockets, isolated from the
desktop session. Each integration target used `-- --output` with its directory
below.

| Check | Result / evidence |
| --- | --- |
| `zig build build-settings build-settings-test test --summary all` | 112 pure tests passed; both frontends built. [Build log](build.log) |
| `zig build test-settings-app` | 21 checks passed. [Results](window/results.json) |
| `zig build test-settings-services` | 26 checks passed: draft transfer, nonzero section scroll/focus restoration, rebuild, recovery, save, recording, and display-preview checks. [Results](services/report.json) |
| `zig build test-settings-presentation` | Theme, text-size, scaling, short-window, and selected-row visibility checks passed. [Results](presentation/results.json) |
| `zig build test-settings-integration` | 8 launch/CLI/desktop integration checks passed. [Results](integration/results.json) |
| `zig build test-aqueous-settings` | 22 shared-editor regression checks passed. [Results](shared-editor/metadata.json) |

Window tests cover all seven child destinations through real input, parent
reentry, external defaults, narrow popover expansion, pointer and keyboard
activation, Escape, and section retention on maximize/restore. Test helpers
scroll the actual navigation instead of bypassing it through an IPC selection.

## Limits of verification

These are private headless compositor tests. Physical-display and manual Orca
review were not performed. Accessible labels and state are implemented; no new
screen-reader transcript is claimed.

Existing content minimum sizes still affect the final window dimensions. With
the requested 480-pixel width, the real Displays page measured 531–538 pixels at
14-pixel text and 739 pixels at 24-pixel text, using the narrow navigation in all
cases. The geometry report records actual dimensions rather than treating the
requested size as achieved. Reworking all editor minimum sizes is separate from
this navigation change.
