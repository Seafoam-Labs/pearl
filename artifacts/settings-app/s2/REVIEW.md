# S2 — Zig executable and reference window

Status: implemented, validated and approved by the user; S3 authorized.
Date: September 15, 2026.

## Delivered

The standalone application is **Zig**, using the repository's pinned GTK4 and
Wayland bindings. Python is used only for private integration fixtures.

- Separate production `pearl-settings` and instrumented `pearl-settings-test`
  build targets. A normal `GtkApplicationWindow` uses the stable
  `org.aqueous.Pearl.Settings` identity and compositor-managed window controls.
- Shared eleven-route sidebar, seven Aqueous subsection IDs, fixed page header
  and footer, one viewport per page, and compact Sections navigation below
  760 logical pixels. The reference-size sidebar is 220 pixels wide; primary
  navigation targets remain at least 44 pixels high.
- Strict launch arguments, per-session instance locking/activation, native/IPC
  identity verification, concurrent-launch handling and crash recovery. Global
  D-Bus instance forwarding is disabled. Closing Settings leaves Pearl running.
- Committed Material light/dark/dynamic palette, native GTK, typography, density
  and reduced-motion support through a read-only backend snapshot. An explicit
  Retry action handles backend loss; the frontend never starts the shell.
- Keyboard navigation separates focus from selection, announces selected pages,
  and restores page-local focus/scroll on internal navigation. Explicit launch
  destinations reset to the heading. Escape dismisses Sections; Ctrl+W closes.
- English and German production navigation/status text. Synthetic cards exist
  only in the instrumented build when `PEARL_SETTINGS_FIXTURE=1` is explicit.

S2 provides the application window and page composition framework. Production
pages show a truthful unavailable state, with disabled save actions. The pictured
sample controls are **test fixtures**, not implemented editors. Appearance and
Advanced editing are S3; remaining editors/services are S4. Packaging, desktop
entry replacement, CLI cutover and flyout handoff remain S5.

## Build and review locally

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build build-settings build-settings-test -Doptimize=ReleaseSafe
./zig-out/bin/pearl-settings --page appearance
PEARL_SETTINGS_FIXTURE=1 ./zig-out/test/pearl-settings-test --page appearance
```

Run from the intended Aqueous session. Generic launches select Overview;
`--page aqueous --section displays` selects the shared Aqueous destination.
Production ignores the fixture environment variable and rejects probe requests.
These targets stage into `zig-out/bin` and `zig-out/test`; system installation
and existing launcher commands are deliberately deferred to S5.

## Validation

All Zig builds use 0.16.0 and `-Doptimize=ReleaseSafe`. App acceptance uses the
pinned private Aqueous 0.8.2 compositor, actual GTK/GIO launch activation, pointer
and keyboard input, production backend and private runtime/config directories.

| Check | Evidence |
| --- | --- |
| Production and instrumented builds; **97/97 pure tests passed** | [Build log](build.log) |
| Standalone launch, lifecycle, navigation and presentation; **19 groups passed** | [Results and binary hashes](results.json), [acceptance log](acceptance.log) |
| Backend handshake, bounds, identity, restart and cleanup; **nine groups passed** | [Results](boundary/result.json), [boundary log](boundary-build.log) |
| Source whitespace and Zig formatting | `git diff --check`, `zig fmt --check` |

The app suite covers shell-absent direct launch, xdg window identity, no shell
surface creation, absent service-agent dependencies, no samples in production,
repeated and concurrent launches, invalid targets, minimized/maximized behavior,
real launcher activation, keyboard/sidebar/page state, committed themes, narrow
layout, 24-pixel text and reduced motion, connection loss/Retry, Ctrl+W cleanup,
production probe rejection, cold-launch races, parent/nested isolation on a
shared D-Bus session, wrong native/IPC identity, and stale-socket recovery.

## Actual window captures

The captures below show the instrumented application, not the HTML mockup.
The surrounding desktop belongs to the isolated compositor fixture.

| Page | Dark | Light | Native GTK |
| --- | --- | --- | --- |
| Appearance | [Image](session/appearance-dark.png) | [Image](session/appearance-light.png) | [Image](session/appearance-gtk.png) |
| Network | [Image](session/network-dark.png) | [Image](session/network-light.png) | [Image](session/network-gtk.png) |
| Bluetooth | [Image](session/bluetooth-dark.png) | [Image](session/bluetooth-light.png) | [Image](session/bluetooth-gtk.png) |
| Sound | [Image](session/sound-dark.png) | [Image](session/sound-light.png) | [Image](session/sound-gtk.png) |
| Power | [Image](session/power-dark.png) | [Image](session/power-light.png) | [Image](session/power-gtk.png) |

Additional evidence: [480-pixel layout](session/appearance-narrow.png),
[Sections popover](session/sections-narrow.png),
[large text](session/appearance-large-text.png),
[production state](session/production-state.png),
[backend unavailable](session/session-unavailable.png).

Compared with the [reference](../../../docs/mockups/settings-navigation/appearance.png),
the app retains the 220-pixel grouped sidebar, lavender selected destination,
rounded separated cards, fixed heading and fixed save footer. Form rows wrap
and the footer stacks at narrow widths. The titlebar uses native GTK window
controls. The wallpaper preview is a synthetic gradient for S2; real image
selection and complete Appearance controls are S3.

## Limits and next checkpoint

- A valid launcher activation token restores a minimized window in the pinned
  compositor. A tokenless invocation selects the requested page but cannot
  override Aqueous's focus-stealing policy. GDK's retained startup notification
  ID is forwarded when GTK has already consumed the environment token.
- Committed appearance currently refreshes through a bounded one-second ping.
  S3's event interface replaces this bridge. Cached appearance revisions are
  invalidated on backend loss so a restarted backend can restyle the window.
- Page widgets remain alive in S2. S3/S4 must use stable focus identities as
  real service/editor bodies begin replacing widgets, and must add the planned
  draft-flush, lock, prompt, preview and owner-interest lifecycle rules.
- Fractional scale/output-removal matrices, physical activation and real
  assistive-technology verification remain S6 acceptance work. Dynamic palettes
  use the existing resolved palette; these captures exercise static and GTK modes.

Approve S2 to proceed to **S3 — real Appearance and Advanced editing**, including
wallpaper dialogs, shared draft authority, Apply/Discard and conflict recovery.
