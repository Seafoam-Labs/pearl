# T00 reference and evidence index

Captured September 13, 2026 with the scripts in this repository. These are actual
screenshots of DMS and the Pearl spike. See [compatibility](../../docs/COMPATIBILITY.md)
for reproducible commands, the distinction between advertised and tested APIs,
and physical checks still required.

## DMS visual baseline

Source revision: `72ca8a6876b014f5722a00f69301a5766653764e`. Quickshell 0.3.1,
Qt 6.11.2, two 1280×720 outputs at scale 1, first output captured. Qt uses its
software renderer; compositor uses pixman. No custom wallpaper was selected:
the visible geometric background is DMS's own fallback. Theme is built-in
`purple`, switched through DMS's `theme dark/light` IPC methods. Settings and
session state are retained in [dms/](dms/), along with IPC calls and logs.

DMS loads bundled Inter Variable and Material Symbols Rounded through
`dank-qml-common/DankCommon/Common/Fonts.qml`; metadata includes their hashes.
The standalone system `fc-match` result in metadata is not Qt's bundled-font
resolution. Pearl's current spike uses system sans-serif; matching DMS's full
component typography is T03 work.

| Surface | Dark | Light |
| --- | --- | --- |
| Bar and fixture dock | [PNG](dms/dms-dark-bar-dock.png) | [PNG](dms/dms-light-bar-dock.png) |
| Launcher | [PNG](dms/dms-dark-launcher.png) | [PNG](dms/dms-light-launcher.png) |
| Control center | [PNG](dms/dms-dark-control-center.png) | [PNG](dms/dms-light-control-center.png) |
| Notification center | [PNG](dms/dms-dark-notifications.png) | [PNG](dms/dms-light-notifications.png) |
| Calendar/dashboard | [PNG](dms/dms-dark-calendar-media.png) | [PNG](dms/dms-light-calendar-media.png) |
| Media empty state | [PNG](dms/dms-dark-media.png) | [PNG](dms/dms-light-media.png) |
| Settings | [PNG](dms/dms-dark-settings.png) | [PNG](dms/dms-light-settings.png) |
| Lock visual demo | [PNG](dms/dms-dark-lock-demo.png) | [PNG](dms/dms-light-lock-demo.png) |

The harness uses the fixed label `pearl-reference`, three harmless local
`.desktop` fixtures pinned to the dock, and a notification sent only on the
private bus. Fixture dock icons fall back to the letter P. Launcher results
include installed system applications; clock/date, machine metrics and that app
inventory are live reference-machine data, so reruns are not pixel-identical.
Layout, palette and density are the baseline, not those changing values.

The Go backend, real system/session services, real media players and tray items
are unavailable in this isolated reference. Populated media artwork/controls
remain an unverified reference; consult DMS's `Modules/DankDash` media components
when implementing T09. Logs retain QML/backend warnings. These captures used
an Aqueous binary explicitly built with `-Dvulkan-effects=false`, so its native
background-effect global is absent. Aqueous advertises that protocol in its
Vulkan-effects builds; these captures do not test it. Panels can look more
transparent than with native blur enabled. Lock captures use
DMS's `lock demo`, never real authentication. These differences must not be
treated as approved final Pearl behavior.

DMS and its common library source are MIT-licensed; notices are retained beside
the captures. No DMS implementation code, font or icon font is vendored into
Pearl by this task. Future copied assets require their own notices.

## Pearl stack proof

- [Normal GTK window](latest/gtk-normal-window.png)
- [Layer-shell bars](latest/gtk-bars.png)
- [Popup with actual typed text](latest/gtk-popup.png)
- [Underlying window after bars unmap](latest/gtk-after-unmap.png)
- [Behavior and baseline results](latest/results.json)
- [Private IPC handshake](latest/hello.json), [initial subscription](latest/snapshot.json),
  [registry](latest/wayland-info.txt), [layout probe](latest/layout.json)
- [Source, package, linker and machine metadata](metadata.json)

The popup screenshot is a binding/focus probe, not the T03 design. Lock evidence
is the API event log plus Aqueous state assertions, not a screenshot of a secure
session. `latest/` and `dms/` contain retained evidence; use a separate output
directory for experiments you do not want to replace it with.
