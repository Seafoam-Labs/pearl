# S4 — Complete sidebar and service flows

Status: implemented, validated and approved by the user; S5 authorized.
Date: September 15, 2026.

The application and backend adapters are **Zig**, using the existing GTK4/GIO
bindings. Python is used for isolated test fixtures and acceptance input.

## Delivered

- Network, Bluetooth, Sound, Power, Notifications, Overview and Session use real
  backend services, capability checks, stable identities and operation receipts.
  Controls include application audio routing, media playback/seek, workspace
  layouts, lifecycle actions and owner-scoped power confirmations. Missing
  services show unavailable states. Scanning and discovery require explicit input.
- Bar & dock and Session edit the same Pearl draft as Appearance and Advanced.
  Invalid intermediate values remain repairable. Service actions remain immediate;
  preference changes still require Apply.
- Aqueous exposes all **221 schema fields** and all seven existing sections,
  including structured collections, display declarations and raw files. Shared
  widgets support either host; validation, persistence and durable receipts remain
  in the original backend. The frontend receives complete documents in bounded
  chunks and uses revision checks for shared draft retention.
- Normal transient credential/pairing dialogs belong to their initiating peer.
  Navigation, lock and disconnect clear owned prompts and discovery without
  canceling another host's work. Secret entries and wire buffers are cleared.
  The network editor uses a fixed desktop application and a normal GDK launch
  context, with useful feedback if unavailable.
- Shortcut recording uses the application's focused toplevel and releases its
  shortcut inhibitor on departure. A separate authenticated Aqueous connection
  keeps display previews alive across sidebar navigation. Keep/Revert remain in
  the fixed footer; close waits for native rollback. Abrupt frontend loss also
  restores the display through backend disconnect/native lease handling.
- Backend restart retains the local candidate for explicit review and Rebase or
  Discard. Mutations are never replayed automatically. Concurrent shared drafts
  cannot be overwritten by local recovery; Review drafts offers a copyable local
  candidate. Canceling an offline close no longer reopens the dialog on reconnect.

## Validation

All commands used `-Doptimize=ReleaseSafe`. Integration tests used private
compositors, private D-Bus services and synthetic audio/backlight devices.
No host preference files or real power actions were used.

| Suite | Result |
| --- | --- |
| Pure tests | 104 passed |
| `test-settings-services` | 22 groups passed |
| `test-settings-devices` | 10 groups passed |
| `test-settings-app` | 19 groups passed |
| `test-settings-appearance` | 15 groups passed |
| `test-settings-boundary` | 9 groups passed |
| `test-settings-lifecycle` | 10 groups passed |
| `test-aqueous-settings` / `test-aqueous-preview` | 22 / 3 groups passed |
| `test-services` / `test-connectivity` / `test-session-services` | 15 / 27 / 18 groups passed |
| `test-surfaces` / `test-desktop` | 17 / 15 groups passed |
| Production `build-settings`, Zig formatting, diff whitespace | Passed |

[Machine-readable validation and report links](validation.json).
The S4 suites exercise actual GTK pointer/keyboard input, owned prompts, stale
writes, a document larger than 64 KiB, the 4 MiB upload bound, real shortcut
recording, preview navigation/foreign-owner rejection, graceful and crash rollback,
acknowledged draft reopening and explicit recovery after backend restart.

## Screenshots

- [Network](acceptance/session/network.png)
- [Bluetooth](acceptance/session/bluetooth.png)
- [Sound with real private PulseAudio devices](devices/session/sound-static-dark.png)
- [Power at 480 pixels with a native GTK theme](devices/session/power-narrow.png)
- [Bar & dock](acceptance/session/bar.png)
- [Aqueous layouts and shared draft](acceptance/session/aqueous-layouts-draft.png)
- [Aqueous structured rules](acceptance/session/aqueous-rules.png)
- [Display preview retained while Sound is selected](acceptance/session/display-preview-during-sound.png)
- [Aqueous recovery after backend restart](acceptance/session/aqueous-recovery-after-backend-restart.png)

The captures are real GTK windows, not mockups. Theme and narrow-layout checks
cover dark, light and native GTK modes. Full physical-monitor scaling, external
application activation, assistive-technology review and final visual comparison
remain part of S6 acceptance.

## Approval boundary

The user approved S4 and authorized S5 packaging and integration. See the
[S5 review](../s5/REVIEW.md) for installation, desktop metadata, CLI launch
compatibility and the compact flyout's **Open full settings** handoff.
