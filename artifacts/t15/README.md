# T15 dock and island evidence

The user's T15 revision replaces the planned desktop frame with detached bar
islands. See [behavior and configuration](../../docs/DOCK_ISLANDS.md).

## Checks

- [T15 scenarios](latest/report.json): private Aqueous, real GIO applications,
  runtime taskbar/switcher flags, fullscreen and geometry-based hiding, edge
  reveal, minimized-window activation, session-inactivity gating, keyboard
  arbitration, per-output orientation, 16-pin scrolling, GTK themes, enlarged
  text, and independent input beneath the visible island bar.
- [Surface regressions](regression/surfaces/results.json): existing 17 checks,
  including native blur/rule veto, transparent input, reservations, reconnect,
  hotplug, fractional scale, rotation and control-socket isolation.
- [Desktop regressions](regression/desktop/results.json): existing GIO discovery,
  launch, window/workspace controls, multi-output and keyboard checks.
- [Preference regressions](regression/preferences/metadata.json): 21 scenario
  groups, including external changes, atomic saves, invalid GTK CSS, recovery,
  dynamic colors, arbitrary GTK themes and persistent drafts.
- [Security regressions](regression/security/report.json): 20 scenario groups,
  including real private native locking, test PAM, logind and polkit lifecycles.
- 99 core/adapter/binding tests (73 + 24 + 2), Zig 0.16.0 ReleaseSafe.

All compositor sessions, buses, application catalogs, themes and PAM stacks are
private fixtures. No host services, settings, clipboard or lock were changed.
The Python input probe preloads GTK layer-shell for correct library order and
uses fatal GTK warnings, as does Pearl. Source/binary hashes are recorded in
[metadata](metadata.json) and the individual reports. Regression runs occurred
during implementation; their reports retain the exact tested binary hashes.

## Visual review

Open [the comparison page](comparison.html) for frozen DMS references alongside
T15 captures. Use the original PNG links for full resolution. Material colors,
rounded groups, spacing and hierarchy follow the reference direction. Deliberate
differences are the detached three-section layout, original symbolic icons,
explicit accessible action-menu buttons, and authoritative Aqueous-only state.
There is no animated dock magnification. GTK mode intentionally follows the
selected theme's colors and controls instead of forcing Material rendering.

| Surface | Current evidence | Additional state/reference coverage |
|---|---|---|
| Islands and dock | [Dark](latest/session/islands-dock-dark.png), [light](latest/session/islands-dock-light.png), [GTK](latest/session/islands-dock-gtk.png) | [DMS dark reference](../t00/dms/dms-dark-bar-dock.png) |
| Dock interaction | [Actions](latest/session/dock-actions.png), [fullscreen reveal](latest/session/fullscreen-reveal.png) | Keyboard/GIO/Aqueous assertions in T15 report |
| Large dock | [16 pins](latest/session/many-pins-large-text.png), [keyboard scroll](latest/session/many-pins-keyboard-scroll.png) | 24 px text and 64 px icons; scrolling is intentional |
| Output layout | [Mixed scale](latest/session/mixed-scale.png), [vertical islands](latest/session/vertical-islands-dock.png), [continuous bar option](latest/session/continuous-bar.png) | Native input probe asserts clicks through island gaps |
| Launcher | [Enlarged](latest/session/large-launcher.png) | [Populated results](regression/desktop/desktop/launcher.png), [T03 reference comparison](../t03/comparison.html) |
| Calendar | [Enlarged](latest/session/large-calendar.png) | [Mixed scale](regression/desktop/desktop/calendar-mixed-scale.png) |
| Control center | [Enlarged](latest/session/large-control.png) | [Audio/power populated states](../t09/regression/test-services/services/control-center-audio-power.png) |
| Notifications | [Enlarged empty state](latest/session/large-notifications.png) | [Populated center](../t09/latest/protocols/notification-center.png) |
| Media | [Enlarged unavailable state](latest/session/large-media.png) | [Populated player](../t09/latest/protocols/media-card.png) |
| Tray | [Enlarged empty state](latest/session/large-tray.png) | [Nested action menu](../t09/latest/protocols/tray-nested-menu.png) |
| Pearl settings | [Enlarged](latest/session/large-settings.png) | [GTK theme](regression/preferences/session/settings-gtk-custom.png) |
| Aqueous settings | [Enlarged](latest/session/large-aqueous-settings.png) | [Protected display preview](../t11/verification/session/display-protected-preview.png) |
| Clipboard/capture | [Enlarged](latest/session/large-clipboard-capture.png) | [Image history](../t14/latest/session/image-history.png), [GTK panel](../t14/latest/session/panel-gtk.png) |
| OSD | [Current surface run](regression/surfaces/surfaces/final-surfaces.png) | [Power feedback](../t09/regression/test-services/services/coalesced-osd.png) |
| Authentication/session | [Identity prompt](regression/security/session/polkit-identities.png), [session controls](regression/security/session/session-controls.png) | Private authority and lifecycle assertions |
| Native lock | [Dark](regression/security/session/native-lock.png), [light](regression/security/session/native-lock-light.png), [GTK](regression/security/session/native-lock-gtk.png) | [T13 enlarged](../t13/latest/session/lock-large-text.png), [short/rotated layouts](../t13/latest/session/lock-rotated-large-text.png) |
| Shared controls | [T03 gallery comparison](../t03/comparison.html) | Disabled, error, pending, narrow and enlarged German states |

New captures cover the T15 layouts and enlarged ordinary panels. Earlier state
captures above remain explicitly identified as earlier evidence; they are not
claims that every service state was reproduced in T15. The reduced-motion path
has no dock animation. Native GTK roles, accessible names and keyboard traversal
are implemented, but AT-SPI speech, physical display/input testing, HDR, multiple
GPUs, 120 Hz presentation and long-run soak remain T16 release acceptance work.
Headless images do not establish those hardware or assistive-technology results.
