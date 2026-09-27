# Default Matugen profiles for the base Material theme

Status: implemented locally September 27, 2026. See [usage and limits](BASE_MATERIAL_PROFILES.md)
and [validation evidence](../artifacts/base-material-matugen/README.md).
The milestone sections below record the implementation contract.

Give Pearl's built-in Material theme a complete Matugen palette and bundled
application defaults covering the requested DMS targets. Selecting the base
theme should be sufficient to resolve useful profiles once application theme
management is enabled. Support static dark/light colors as well as the existing
dynamic seed and wallpaper modes.

“Default” means bundled and assigned by the base theme. Keep external application
management opt-in, as it is today. Existing manual choices and Off selections
survive every theme change. This plan extends the
[application profiles](MATUGEN_PROFILES_IMPLEMENTATION_PLAN.md) and
[live wallpaper updates](MATUGEN_WALLPAPER_LIVE_UPDATE_PLAN.md) already implemented.

## Inspected starting point

- [theme.zig](../src/theme/theme.zig) contains the built-in dark/light palettes,
  with 13 shell roles. These alone cannot render full Material application themes.
- [theme_provider.zig](../src/theme/theme_provider.zig) inherits assignments only
  from an active package. With Follow Pearl colors, static and GTK modes supply
  no complete render data; `refreshColors` explicitly clears it.
- [matugen_profiles.zig](../src/theme/matugen_profiles.zig) supports only Zed,
  Equibop, Fluxer, Starship and Steam. Output validation assumes JSON, TOML or CSS.
  Status, selection hashing, the service and Settings contain five-element arrays.
- [application_profiles.zig](../src/theme/application_profiles.zig) already has
  private Matugen rendering, immutable snapshots, caching, ownership journals,
  conflict handling and restoration. Its current destination logic is specific
  to the initial applications and principally rooted in XDG config storage.
- [Qt integration](QT_THEMING.md) already manages QtEngine + Darkly for Qt 5/6,
  including a generated KDE scheme. It must remain the sole writer of those
  settings.

The coverage baseline is the local DMS checkout at
`72ca8a6876b014f5722a00f69301a5766653764e`, inspected in
`/home/zoey/DankMaterialShell`. Source references are its
[template registry](https://github.com/AvengeMedia/DankMaterialShell/blob/72ca8a6876b014f5722a00f69301a5766653764e/core/internal/matugen/matugen.go),
[template configurations](https://github.com/AvengeMedia/DankMaterialShell/tree/72ca8a6876b014f5722a00f69301a5766653764e/quickshell/matugen/configs),
and [Settings controls](https://github.com/AvengeMedia/DankMaterialShell/blob/72ca8a6876b014f5722a00f69301a5766653764e/quickshell/Modules/Settings/ThemeColorsTab.qml).
This is a pinned coverage baseline, not a claim about future upstream versions.

## Coverage contract

Niri, Hyprland, MangoWC and dgop are excluded from this plan at the user's request.
Every remaining DMS registry target must have a validated output or existing
Pearl integration. Generation, installation and activation
are separate capabilities; a generated file alone is not proof of live theming.

| DMS targets | Planned Pearl support and activation |
| --- | --- |
| GTK | Material CSS for GTK 3 and GTK 4, with Pearl-owned imports and conditional restoration. Explain the GTK theme dependencies and application limitations. |
| qt5ct, qt6ct | Generate selectable palette files for users of those tools. Keep these exports opt-in; do not switch Pearl's session away from QtEngine or restore qtct as a runtime dependency. |
| kcolorscheme, QtEngine | Publish selectable KDE schemes; present the existing QtEngine + Darkly controls and status in the same application-theme area. Reuse the Qt writer for activation. |
| Ghostty, Kitty, Foot, Alacritty, WezTerm | Pearl-named theme/include files in each application's native format. Include Kitty's tab colors. Show the exact include/theme selection needed for activation. |
| Neovim | Colorscheme and lualine theme, with explicit setup instructions and no edits to arbitrary Lua configuration. |
| VS Code family | Pearl theme extension assets, covering the editor variants detected in the pinned DMS source. Support local installation and activation without requiring a marketplace publication. |
| Emacs | Pearl theme file and load instructions; account for supported Emacs configuration roots. |
| Zed | Built-in Material profile with dark/light themes alongside the existing Seafoam choice. |
| Firefox, Zen Browser | Browser chrome CSS and instructions for choosing a browser profile, importing the stylesheet and enabling its prerequisite settings. Never guess which browser profile to modify. |
| pywalfox | Compatible palette JSON, including the shared wal destination only when selected; detect and preserve another writer's files. Offer a bounded built-in refresh action when the helper is available. |
| Vesktop, Vencord, Equibop | Pearl Material CSS and native/Flatpak paths where supported by the baseline; activation remains visible in the client. |
| Fcitx5 | Theme configuration plus panel/highlight assets under XDG data storage; expose theme selection and supported reload behavior. |

Keep Fluxer, Starship and Steam available and add base Material assignments for
them too. They are existing Pearl targets beyond this DMS registry. Preserve
Starship's reviewed installation flow and Steam/Fluxer's activation requirements.
Do not relabel the existing Seafoam profiles as the base Material profiles.

Aqueous appearance continues through Pearl's existing supported integration.
Inventory its supported color fields during implementation; any new compositor
API is a separate, explicit dependency rather than an invented DMS-compatible
configuration destination.

## Palette and default resolution

1. Add a built-in provider with a stable identity such as `pearl.material` and
   versioned assignments such as `pearl.material.ghostty`. Reserve its profile
   namespace so installed packages cannot replace built-in assets by collision.
   Keep the shell's existing empty-package representation compatible; a built-in
   provider need not masquerade as an installed community package.
2. Bundle complete, validated Matugen render documents for static dark and light.
   Preserve the exact existing 13 shell colors, all required Material roles,
   base16 values and tonal palettes. Record a reproducible generation/adjustment
   recipe and verify color projections with `render_data.validate`. Generating
   from `#6750a4` alone is not proof that all current static colors match.
3. Static Material uses these documents without running palette extraction.
   Template rendering still requires a supported Matugen executable. Dynamic
   Material reuses the committed full JSON produced by the existing generator.
   Independent application seed/wallpaper choices keep their existing behavior.
4. Update both capture and refresh paths so static render data survives refresh,
   Retry and restart. Include built-in asset/palette versions in snapshot and
   color identities. Cache keys must distinguish static palette changes even
   when the application seed setting has not changed.
5. Resolve assignments in this order: management disabled → unmanaged; explicit
   Off → unmanaged; explicit profile → that profile; Follow theme → active
   package assignment, or built-in assignment when the base Material theme is
   active. A package with no assignment stays unmanaged. GTK mode has no implicit
   Material assignment or palette; independent colors remain available.
6. Keep template assignment, palette source and widget style independent.
   Choosing a community widget style must not accidentally replace base theme
   application assignments. Preserve the existing package-selection semantics.

Port DMS-only expressions such as `dank16` to an explicit, documented Pearl
terminal-role mapping based on the complete render data. Audit all template
variables and terminal customization inputs. This work promises application
coverage and coherent Material colors, not identical DMS terminal harmonization
or every DMS tuning control. Verify contrast and ANSI distinctions in both modes.

## Implementation sequence

### M1 — Freeze the inventory and generalize target metadata

Create a machine-readable coverage fixture mapping each in-scope pinned DMS
registry ID and QtEngine to a Pearl target, output formats, installation roots, dependencies,
supported variants and activation method. Include native and supported Flatpak
layouts, editor variants, and any user-selected instance/profile requirement.

Extend `matugen_profiles.zig` with typed target metadata. Replace application
five-element assumptions in `theme_provider.zig`, `config/service.zig`,
`settings/profiles_view.zig` and their protocol/tests with registry-derived
storage. Persist and exchange target identities explicitly rather than depending
on enum position. Update readers together and version changed status/snapshot
formats; retain readers for previously committed five-target snapshots.

Expand output validation per adapter to include INI/conf, Lua, Elisp, SVG
and extension assets. Adapters own destinations and allowed file roles. Keep
bounded catalogs, output sizes and snapshot storage; verify the target count
against the current 32-entry preference limit. Do not reinterpret unrelated
five-element arrays, such as Qt ownership hashes, as target lists.

**Done when:** the inventory accounts for all in-scope baseline targets, old preferences
and snapshots load, and every target has a declared output/activation contract.

### M2 — Add the built-in Material provider

Implement the palette and precedence rules above, bundle base templates under
`src/theme/material/pearl.material.*`, and update `build.zig` installation rules.
Ship the palette input with Pearl so static shell operation remains independent
of Matugen availability. Keep all committed template bytes immutable until the
user adopts updated profiles through the existing workflow.

Protect upgrades from expanding an already-enabled user's managed applications:
introduce a versioned default-assignment adoption value, with absence meaning
legacy assignments. Show **Use Material defaults** as a shared-draft action that
adopts the new assignment set while preserving manual and Off choices. Fresh
enablement adopts the current set; later releases require adoption for newly
added targets. An unrelated preference Apply must not adopt new targets.

**Done when:** base static dark/light and dynamic themes resolve defaults,
manual/Off/package behavior is preserved, and upgrades perform no new external
writes until the relevant assignments are adopted and committed.

### M3 — Implement file adapters and application detection

Extend the existing worker and ownership journals for validated XDG config,
data and cache roots. Install Pearl-named files where applications support them;
use reviewed, narrowly scoped imports or settings edits when activation requires
changing an existing file. Preserve user content, comments where applicable,
backups and compare-before-replace restoration. Symlinks or ambiguous roots
must not redirect writes outside the selected destination.

Deliver terminals and editors first, then chat/browser clients and utilities.
Fcitx5 needs a coherent multi-file theme; VS Code needs a complete installable
extension rather than only JSON colors. Validate all files before publication,
record interrupted multi-file work and ensure Retry repairs it. Detection is a
bounded backend operation triggered by relevant changes or explicit refresh,
not idle polling. Missing applications retain saved choices and expose an
honest unavailable/setup state.

Use only typed built-in reload actions with argument vectors, timeouts and
cancellation. Preserve manual activation when no supported refresh mechanism
exists. Contributed profiles never supply executable hooks. Do not copy DMS's
global configuration execution, extension installation side effects or broad
process signaling into Pearl's profile renderer.

**Done when:** each target renders, installs where supported, reports activation
accurately, and can be disabled/restored without losing user edits.

### M4 — Integrate GTK and Qt/KDE

Implement GTK imports with separate GTK 3/4 ownership and dependency status.
Verify against real applications and confirm that GTK shell mode does not create
a feedback loop in palette generation.

Keep Qt preferences and ownership in the existing Qt subsystem. Application
themes should link to or edit the same Qt draft fields, never maintain a second
enable switch or competing writer. Label Qt's existing Follow Pearl semantics
clearly: an independent Matugen application seed does not silently change Qt.
Generate optional qtct palettes and KDE exports through adapters, sharing
serialization where practical without duplicating managed Qt destinations.

**Done when:** GTK applications and both available Qt runtimes show committed
colors and toolkit managers do not overwrite one another.

### M5 — Finish Settings, packaging and documentation

Group the application list by toolkits, terminals, editors, browsers, chat and
other tools. Retain search and Follow theme / Choose profile / Off. Show the
effective profile, “Base Material” origin, detection, output location and setup
instructions per target. Distinguish generated, installed, activation required,
applied, missing dependency and conflict states. Explain missing Matugen without
preventing the static Pearl shell from working.

All selection changes use the existing shared draft and Apply/Discard behavior;
opening Settings and previews perform no external writes. Generalize reviewed
installation actions where necessary while retaining Starship's existing flow.
Verify keyboard navigation and usability with the much longer target list.

Install all default assets in distribution packages and development staging.
Record pinned source, license and modifications for every reused template and
asset, including individual notices. Update `CUSTOM_THEMES.md`, `PREFERENCES.md`,
`QT_THEMING.md`, `DEVELOPMENT.md`, `RELEASE.md` and the README application-theme
entry. Explain migration, adoption, activation and conditional restoration.

**Done when:** a fresh installation can choose base Material, enable the desired
targets, follow their setup instructions and retain those choices across restart.

## Acceptance and execution order

Run M1 → M2 → M3 → M4 → M5. A working five-profile demo completes only part of
M2; DMS coverage remains unfinished until every coverage-fixture row is verified.

- Render every built-in template in dark and light, or explicitly document a
  real variant restriction. Require both variants for the base toolkit and
  terminal defaults. Parse structured output with independent validators, check
  unresolved template expressions and load representative files in real apps.
- Prove exact static shell-role projections; test dynamic seed, wallpaper changes,
  same-path image replacement, variant switches, rapid changes and stale jobs.
  Reuse one extraction per matching source and the existing generation lifecycle.
- Test old enabled and disabled preferences, new-target adoption, manual/Off
  persistence, package/GTK transitions, old snapshots, removed installed assets,
  committed Retry and restart. A default profile update must not silently replace
  pinned assets.
- Exercise missing Matugen/app/helper, invalid templates, edited destinations,
  interrupted multi-file writes, unavailable Flatpak roots, multiple browser
  profiles, custom config roots and another writer of shared wal files. Failures
  retain last-good outputs and do not undo successful shell/other-target updates.
- Verify GTK 3/4 and Qt 5/6 colors in private sessions, toolkit ownership
  conflicts, full Off/restoration, Settings Apply/Discard, keyboard access and
  the absence of host configuration changes during tests.
- Test installation from a staged package without source-tree paths or DMS
  installed. Record rendered outputs, representative app screenshots and any
  unverified manual activation under `artifacts/base-material-matugen/`.

Add a focused `test-base-material-profiles` target for the coverage inventory,
palette/provider contract and new adapters. Run relevant existing
`test-matugen`, `test-wallpaper-profiles`, `test-theme-completion`,
`test-preferences`, `test-settings-appearance` and `test-qt-theme` checks as their
implementation paths change. Keep all writes in private XDG roots and use nested
Aqueous sessions for visual/runtime verification. Document unavailable optional
application checks rather than reporting them as passed.
