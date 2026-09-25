# Pearl

Pearl is a **Zig 0.16 + GTK4 desktop shell built exclusively for Aqueous**, with a look and feel closely modeled on Dank Material Shell.

Pearl's initial design and implementation used **spec-driven development**. Written specifications defined the product's behavior, visual direction, architecture and acceptance criteria before implementation. Those specifications guided AI-assisted implementation and verification, keeping the work tied to explicit requirements and testable outcomes.

Version **1.0.0-rc.2** includes floating islands, a dock, migration tooling and Arch packaging. Release acceptance is pending the physical, real-login, accessibility and license gates in [RELEASE.md](docs/RELEASE.md).

The pinned Zig 0.16.0 stack has generated
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
retained drafts, structured collection editors, shortcut recording and compositor-owned
display previews. Structured save receipts survive interrupted helper calls and Pearl
restarts. The current integration pins Aqueous master `8858724` and aqueous-config
0.8.2; structured collections now save and display declarations/profiles have typed editors; hardware-gated operations show their [upstream dependency](docs/AQUEOUS_MASTER_DEPENDENCIES.md).
Session actions, a real polkit agent, AC/battery idle policies and a native
Noctalia-like GTK/PAM lock screen are now implemented. Physical security/session
acceptance remains pending. Clipboard history, SDR output/region capture, floating bar islands and a configurable dock are implemented. All available workspaces appear on the bar: horizontal bars wrap when needed; vertical bars keep a single column and scroll overflow while retaining their thickness.

- [Aqueous 0.8.2 integration evidence](artifacts/aqueous-082/README.md) and [previous master UI gallery](artifacts/aqueous-master/README.md).
- [Release and packaging](docs/RELEASE.md) and [DMS migration / switch-back](docs/MIGRATION.md).
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md): scope, visual design, architecture, integration contracts, release gates, and risks.
- [Launcher button icons](docs/PREFERENCES.md#launcher-button-icon): choose bundled or installed theme icons, or a local PNG, with draft preview, live Apply, Reset and Retry. [Implementation plan](docs/LAUNCHER_ICON_IMPLEMENTATION_PLAN.md).
- [Custom launcher selection](docs/DOCK_ISLANDS.md#custom-application-launchers): choose a custom desktop entry for running applications, preserve its icon and launch arguments, and correct existing pins. [Implementation and tests](docs/DOCK_DESKTOP_OVERRIDES_IMPLEMENTATION_PLAN.md) for issue #3.
- [Preferred custom launchers](docs/DOCK_LAUNCH_ATTRIBUTION_PLAN.md): issue #3 matching and pinning improvements, including matching custom pins and desktop IDs with spaces/Unicode; no Aqueous update required.
- [Experimental WebAssembly plugins](docs/PLUGINS.md): C, Zig and Rust components, native widgets and companion overlays, with controls in the main Settings app. [Implementation roadmap](docs/WASM_PLUGIN_IMPLEMENTATION_PLAN.md).
- [Plugin development guide](docs/PLUGIN_DEVELOPMENT.md): build your first clickable widget, install and test it, then add settings, timers or an animated companion.
- [Live plugin input activity plan](docs/PLUGIN_INPUT_ACTIVITY_IMPLEMENTATION_PLAN.md): implemented Aqueous integration for typing reactions, with permission and authentication controls; physical hardware acceptance remains open.
- [Live plugin discovery plan](docs/PLUGIN_LIVE_RELOAD_IMPLEMENTATION_PLAN.md): install, update and remove plugins without restarting Pearl, with automatic discovery and package approval.
- [Settings-flyout navigation plan](docs/SETTINGS_NAVIGATION_PLAN.md): proposed direct bar shortcuts and separate compact settings pages.
- [Workspace window switcher plan](docs/WINDOW_SWITCHER_IMPLEMENTATION_PLAN.md): cycle through the current workspace with a sliding window stack; includes an interactive mockup and required Aqueous integration.
- [Standalone Settings application plan](docs/STANDALONE_SETTINGS_APPLICATION_PLAN.md): a separately launchable Settings app, sidebar pages, backend integration, packaging and design mockups.
- [Qt application theming](docs/QT_THEMING.md): opt-in QtEngine + Darkly application styles for Qt 5/6, Pearl palettes, font/density settings, session setup and conditional restore. [Milestones](docs/QT_DARKLY_IMPLEMENTATION_PLAN.md) record delivery and remaining compatibility checks.
- [Aqueous integration update plan](docs/AQUEOUS_MASTER_UPDATE_PLAN.md): implementation scope and acceptance for the pinned master contracts.
- [Aqueous 0.8.2 update plan](docs/AQUEOUS_082_UPDATE_PLAN.md): adopt newly exposed collection transactions, display declarations and preview controls.
- [Greeter](docs/GREETER.md): a separate greetd login screen and installed-desktop chooser, with Material/GTK themes and private tests. Runs on ordinary Aqueous, with a [standalone Arch package](packaging/arch-greeter/README.md) that installs defaults and selects Pearl for the next boot. Real-login validation remains pending.
- [Fingerprint integration](docs/FINGERPRINT_LOGIN.md): PAM-controlled password fallback, automatic scan messages, locker compatibility and private tests; [real-device acceptance remains open](docs/FINGERPRINT_LOGIN_IMPLEMENTATION_PLAN.md).
- [Development specification](docs/TASKS.md): implementation scope, dependencies, concrete deliverables, and acceptance criteria.
- [Compatibility and reproduction](docs/COMPATIBILITY.md): verified dependencies, commands, capability gaps and baseline results.
- [Development guide](docs/DEVELOPMENT.md): run the gallery, use isolated sessions, and follow lifecycle/ownership conventions.
- [Aqueous model](docs/AQUEOUS_MODEL.md): decoder limits, atomic updates, derived views and ownership contracts.
- [Aqueous adapter](docs/AQUEOUS_ADAPTER.md): persistent connections, command completion, recovery and icon caching.
- [Live desktop](docs/DESKTOP.md) and [DMS/Pearl comparison](artifacts/t06/comparison.html): bar, GIO launcher, calendar, control center and native layout controls.
- [Aqueous settings replacement](docs/AQUEOUS_SETTINGS.md), [field coverage](docs/AQUEOUS_FIELD_INVENTORY.md) and [master capability coverage](docs/AQUEOUS_CAPABILITY_COVERAGE.md). Open it with `pearlctl aqueous show`.
- [Session security and native lock](docs/SESSION_SECURITY.md): idle/sleep, polkit, native GTK/PAM locker, packaging and physical acceptance.
- [Clipboard and screenshots](docs/CLIPBOARD_CAPTURE.md): private history, native output/region capture, isolated-source selection with color validation, save/copy controls and lock behavior.
- [Native lock screen](docs/LOCK_SCREEN.md): responsive input, accessibility, output lifecycle and resource verification.
- [Preferences, wallpaper and themes](docs/PREFERENCES.md) and [theme visual evidence](artifacts/t10/comparison.html): settings, dynamic Material colors, native GTK themes, draft recovery and opt-in exports.
- [Night Light](docs/NIGHT_LIGHT.md): saved temperature/schedule controls and native Aqueous warming; physical output qualification remains pending. [Implementation plan](docs/NIGHT_MODE_IMPLEMENTATION_PLAN.md).
- [Application themes](docs/CUSTOM_THEMES.md#application-management-and-recovery): opt-in Matugen profiles, package defaults, independent app choices and owned-file recovery.
- [Community themes](docs/CUSTOM_THEMES.md): configurable HTTPS repositories, independent palettes/styles, static image assets, automatic local discovery and native Zig author tools. Start with the [step-by-step theme creation guide](docs/CREATE_COMMUNITY_THEME.md). [Repository publishing](docs/THEME_REPOSITORIES.md) and [completion plan](docs/CUSTOM_THEMES_COMPLETION_PLAN.md) for images, automatic discovery, application profiles and the default GitHub repository.
- [Notifications, tray and media](docs/SESSION_SERVICES.md) and [session-service visual evidence](artifacts/t09/comparison.html): protocol contracts, bounds, keyboard controls, ownership and session-bus recovery.
- [Network and Bluetooth](docs/CONNECTIVITY.md) and [connectivity visual evidence](artifacts/t08/comparison.html): connection/pairing agents, bounded discovery, credential handling and hardware acceptance.
- [Audio and power](docs/SERVICES.md) and [audio/power visual evidence](artifacts/t07/comparison.html): service behavior, CLI, permissions and physical release checks.
- [Surfaces and CLI](docs/SURFACES.md): output identity, reservations, popup/input policy, native blur and control v1.
- [Components](docs/COMPONENTS.md) and [DMS visual comparison](artifacts/t03/comparison.html): gallery controls, keyboard behavior and captured differences.
- [Generated bindings](bindings/README.md): full layer-shell/session-lock namespaces sharing Ghostty's GTK types, with no C bridge.
- [Progress](docs/PROGRESS.md) and [visual references](artifacts/t00/REFERENCES.md).

## Settings

Open **Pearl Settings** from the launcher, pin it to the dock, or run:

```sh
pearl-settings
pearlctl settings show --page appearance
pearlctl aqueous show --section displays
```

The Zig application is a normal window, with one instance per verified Aqueous
session. Repeated launches select the requested page and activate that window.
The bar keeps its compact controls; **Open full settings** opens their matching
application page. Pearl must be running to edit; direct `pearl-settings` can show
an unavailable-session window with Retry. It never starts a second shell.

Device controls take effect immediately. **Apply & save** saves the shared Pearl
preference draft; Aqueous has its own explicit Apply and display-preview flow.
Acknowledged drafts survive closing the window while the backend remains alive.
Backend loss retains a local copy for explicit recovery without replaying writes.
See [Preferences](docs/PREFERENCES.md) and [Aqueous Settings](docs/AQUEOUS_SETTINGS.md).

## Development commands

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
```

To see the gallery inside a separate compositor window on your Wayland desktop:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build gallery -Doptimize=ReleaseSafe -Ddev-backend=nested
```

See the development guide for prerequisites and test commands, and the release
guide for the remaining acceptance checks.

The original specification is based on local Aqueous and DMS source inspected on September 13, 2026, plus upstream GTK and Ghostty documentation.
