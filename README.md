# Pearl

Pearl is a **Zig 0.16 + GTK4 desktop shell built exclusively for Aqueous**, with a look and feel closely modeled on Dank Material Shell. Version **1.0.0-rc.1** includes floating islands, a dock, migration tooling and Arch packaging. Release acceptance is pending the physical, real-login, accessibility and license gates in [RELEASE.md](docs/RELEASE.md).

T00–T07 and T09–T10 are complete; T08 and T11–T14 are implemented with their documented capability and physical-acceptance boundaries. The pinned Zig 0.16.0 stack has generated
layer-shell/session-lock bindings, an application lifecycle, compiled GTK
resources and a demo gallery. Private Aqueous tests cover startup, shutdown,
cancellation and session isolation. A bounded Aqueous decoder and atomic state
model pass pure protocol tests. The gallery now includes dark/light Material
components, compact density, larger text, translations and virtualized search.
Session mode now maintains two Aqueous connections with validated commands,
reconnect recovery and bounded window icons. Session surfaces now include per-output
wallpaper and bar, modal popup, click-through OSD and frame reservations, native
Aqueous blur and the session-scoped `pearlctl` CLI. The first desktop slice now
includes configurable live bar groups, GIO application/window search and launch,
a local calendar, and a control center with native Aqueous layout controls.
Audio devices/streams, battery, brightness, power profiles and bounded OSD feedback
are connected. Power-off/restart controls require confirmation. NetworkManager
Wi-Fi/saved profiles and BlueZ pairing/discovery now have real service agents and
GTK controls. Physical enumeration passed; the opt-in hardware scan remains
pending. Notifications/history/DND, StatusNotifier tray menus and MPRIS media controls
are now connected, with owner-safe session-bus recovery and bounded local artwork.
Preferences, per-output bar policies, wallpaper, dynamic Material palettes, and
native system/installed GTK4 themes now update the shell live. Settings drafts
survive external edits, with conflict-aware merging and atomic persistence.
Pearl now replaces the Aqueous settings frontend, with schema-driven GTK pages,
retained drafts, shortcut recording and an independent display-preview guardian.
Session actions, a real polkit agent, AC/battery idle policies and a native
Noctalia-like GTK/PAM lock screen are now implemented. Physical security/session
acceptance remains pending. Clipboard history, SDR output/region capture, floating bar islands and a configurable dock are implemented. All available workspaces stay visible and wrap when needed.

- [Release and packaging](docs/RELEASE.md) and [DMS migration / switch-back](docs/MIGRATION.md).
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md): scope, visual design, architecture, integration contracts, release gates, and risks.
- [AI implementation tasks](docs/TASKS.md): ordered work packages with dependencies, concrete deliverables, and acceptance criteria.
- [Compatibility and reproduction](docs/COMPATIBILITY.md): verified dependencies, commands, capability gaps and baseline results.
- [Development guide](docs/DEVELOPMENT.md): run the gallery, use isolated sessions, and follow lifecycle/ownership conventions.
- [Aqueous model](docs/AQUEOUS_MODEL.md): decoder limits, atomic updates, derived views and ownership contracts.
- [Aqueous adapter](docs/AQUEOUS_ADAPTER.md): persistent connections, command completion, recovery and icon caching.
- [Live desktop](docs/DESKTOP.md) and [DMS/Pearl comparison](artifacts/t06/comparison.html): bar, GIO launcher, calendar, control center and native layout controls.
- [Aqueous settings replacement](docs/AQUEOUS_SETTINGS.md), [field coverage](docs/AQUEOUS_FIELD_INVENTORY.md) and [T11 verification](artifacts/t11/verification/README.md). Open it with `pearlctl aqueous show`.
- [Session security and native lock](docs/SESSION_SECURITY.md): T12 idle/sleep, polkit, native GTK/PAM locker, packaging and physical acceptance.
- [Clipboard and screenshots](docs/CLIPBOARD_CAPTURE.md): T14 private history, native output/region capture, save/copy controls and lock behavior.
- [Native lock screen](docs/LOCK_SCREEN.md): T13 responsive input, accessibility, output lifecycle and resource verification.
- [Preferences, wallpaper and themes](docs/PREFERENCES.md) and [T10 visual evidence](artifacts/t10/comparison.html): settings, dynamic Material colors, native GTK themes, draft recovery and opt-in exports.
- [Notifications, tray and media](docs/SESSION_SERVICES.md) and [T09 visual evidence](artifacts/t09/comparison.html): protocol contracts, bounds, keyboard controls, ownership and session-bus recovery.
- [Network and Bluetooth](docs/CONNECTIVITY.md) and [T08 visual evidence](artifacts/t08/comparison.html): connection/pairing agents, bounded discovery, credential handling and hardware acceptance.
- [Audio and power](docs/SERVICES.md) and [T07 visual evidence](artifacts/t07/comparison.html): service behavior, CLI, permissions and physical release checks.
- [Surfaces and CLI](docs/SURFACES.md): output identity, reservations, popup/input policy, native blur and control v1.
- [Components](docs/COMPONENTS.md) and [DMS visual comparison](artifacts/t03/comparison.html): gallery controls, keyboard behavior and captured differences.
- [Generated bindings](bindings/README.md): full layer-shell/session-lock namespaces sharing Ghostty's GTK types, with no C bridge.
- [Progress](docs/PROGRESS.md) and [visual references](artifacts/t00/REFERENCES.md).

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
```

To see the gallery inside a separate compositor window on your Wayland desktop:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build gallery -Doptimize=ReleaseSafe -Ddev-backend=nested
```

See the development guide for prerequisites and test commands. The T00 spike
remains a test executable; the application is not yet a complete desktop shell.

Start with the plan's product brief, then use the task list to implement one verifiable slice at a time. The plan is based on local Aqueous and DMS source inspected on September 13, 2026, plus upstream GTK and Ghostty documentation.
