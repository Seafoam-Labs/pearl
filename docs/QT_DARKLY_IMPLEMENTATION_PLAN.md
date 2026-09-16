# Qt application theming with Darkly

**Platform revision:** The user selected QtEngine + Darkly application style,
without KWin decorations. The qtct-specific design below is historical. Current
implementation, migration, packaging and test contracts are in [QT_THEMING.md](QT_THEMING.md)
and [QtEngine evidence](../artifacts/qtengine/README.md).

Status: implemented native integration, September 16, 2026. Darkly is the Qt
widget style base. [Usage and recovery](QT_THEMING.md) describe the delivered
contract; [test evidence](../artifacts/qt-darkly/README.md) records validation.
The milestone specifications below retain the broader acceptance work.

| Milestone | Delivered status |
| --- | --- |
| Q1 | Real Qt 5/6 consumers and isolated load probes pass; binary hashes and inspected source revision recorded separately |
| Q2 | Default-off strict preferences, target status/revisions, shared draft and backend actions implemented |
| Q3 | Complete palettes, Qt font round trip, icons and Darkly adapters implemented and exercised |
| Q4 | Lossless key edits, per-target write-ahead ledgers, writer lease, conditional restore and reviewed repair tested |
| Q5 | Direct-login/UWSM hooks packaged; marker rules tested; fresh physical-login propagation remains unverified |
| Q6 | Committed worker reconciliation, retry, dynamic seed/wallpaper and live Qt Widgets palette updates tested |
| Q7 | Full Appearance controls, compact status/link, conflict review and restore delivered; physical/AT-SPI speech acceptance remains open |
| Q8 | Optional radius, motion and compact density delivered; real geometry/scaled-font checks and screenshots retained |
| Q9 | Qt Quick/Kirigami palette inheritance classified partial; four optional KDE keys supported; Dolphin/Kate and Flatpak unsupported pending validation |
| Q10 | Stable/Git packaging, docs and staged release checks delivered; physical release acceptance remains open |

Implementation consolidates the pure adapters in `src/theme/qt.zig` and the
worker in `src/config/qt_integration.zig`. Per-target ledgers contain the recovery
transaction directly, avoiding a separate transaction directory. The inspected
Darkly source is 0.5.39; the tested installed binaries have unknown source revision,
so no source-version-wide compatibility claim is made.

## Outcome

Pearl Settings can enable Qt appearance management and make supported Qt 5 and
Qt 6 applications use Darkly with Pearl's committed colors, font and icon theme.
Wallpaper-derived colors update through the existing Material generator.
Selected Darkly geometry and animation settings are managed through the same
Pearl draft and Apply workflow. Users can disable management and restore values
Pearl replaced without losing subsequent edits made outside Pearl.

The first release covers native Qt Widgets applications on Aqueous. Qt Quick,
KDE-specific color consumers and Flatpak receive explicit compatibility results;
broader support is delivered in the follow-up milestones below.

## Existing foundation and integration points

| Area | Existing code | Planned work |
| --- | --- | --- |
| Palette and generation | `src/theme/theme.zig`, `src/theme/generator.zig` | Reuse validated static/dynamic palettes; add Qt role conversion |
| Strict preferences | `src/config/preferences.zig` | Add bounded, optional Qt management settings |
| Preparation and commit | `src/config/service.zig` | Prepare Qt changes with a candidate; reconcile only committed preferences |
| Protected file I/O | `src/config/io.zig` | Reuse compare-before-replace and private snapshots; add shared-file ownership semantics |
| Drafts and conflicts | `src/config/draft.zig`, `src/config/merge.zig` | Preserve shared drafts and three-way preference merging |
| Settings frontend | `src/settings/preferences_view.zig`, `src/settings/editor.zig`, `src/settings/window.zig` | Add Qt Appearance controls and integration results |
| Settings transport | `src/settings/backend.zig`, `src/settings/editor_protocol.zig` | Expose capability, desired/applied revision and retry/restore results |
| Compact editor | `src/desktop/settings.zig` | Show a concise status and link to full Appearance; retain Advanced access |
| Application launch | `src/desktop/launcher.zig` | Verify GIO launch/activation environment propagation |
| Session entry | `packaging/examples/uwsm-env-aqueous`, `packaging/examples/aqueous-init-pearl`, `packaging/greeter/pearl-aqueous-session` | Establish Qt environment before applications start |
| Packaging | `packaging/arch/PKGBUILD`, `packaging/arch-git/PKGBUILD`, `packaging/install.sh` | Declare optional integration dependencies and install session support |
| Private tests | `scripts/pearl_session.py`, `tests/integration/test_preferences.py`, `build.zig` | Add Qt fixtures, isolated integration tests and release evidence |

Today, generic exports only write beneath `$XDG_CONFIG_HOME/pearl/exports` and
reject Material exports in GTK mode. Their whole-file ownership marker cannot
simply be reused to take ownership of an existing qtct configuration. Keep that
export contract intact; introduce a dedicated Qt integration adapter.
See [preferences and exports](PREFERENCES.md).

## Design decisions

### Responsibilities

Pearl remains the Zig/GTK settings authority. Qt applications load the installed
Darkly style and qtct platform plugins themselves. Runtime Qt probes, if needed,
are separate, short-lived executables; no Qt linkage is added to the Pearl shell.

Use qt5ct/qt6ct for native application platform integration, palette selection,
font and icon settings. Use Darkly for widget drawing and its own supported
options. The style base is fixed to Darkly in this first implementation; there
is no general-purpose style marketplace or arbitrary QSS editor.

The upstream [Darkly documentation](https://github.com/Bali10050/Darkly) describes
Qt 5/6 installation and activation through qtct. Runtime selection must be
verified against installed packages rather than inferred from executable names.

### Scope of management

Management is off by default. Enabling it and applying the shared draft opts in
to changes to the documented Qt appearance keys. Package installation never
enables management or rewrites user configuration.

Qt configuration is normally shared by applications using the same user's XDG
configuration directory. State that scope in Appearance: these changes can
affect Qt applications outside Pearl too. Session environment changes belong
only to the verified Pearl/Aqueous login path. A nested development session uses
private configuration and a private bus and must not alter the host user manager.

A second Pearl instance targeting the same managed files must observe a single
writer lease. Another desktop's active configuration edits are external edits,
not changes Pearl should continually overwrite.

### Delivered preference model

This optional object extends the current version-1 preferences. Defaults:

```json
{
  "qt": {
    "enabled": false,
    "style": "darkly",
    "targets": { "qt5": true, "qt6": true },
    "palette": "follow_pearl",
    "sync_font": true,
    "icon_theme": "",
    "darkly": {
      "corner_radius": null,
      "sync_reduced_motion": true,
      "sync_density": false,
      "sync_kde_colors": true
    }
  }
}
```

- `palette`: `follow_pearl`, `static_dark`, or `static_light`. Following Pearl
  uses its committed static/dynamic palette. When Pearl uses GTK mode, explicitly
  use Pearl's static palette for the selected variant and label that fallback.
  Do not try to infer an arbitrary GTK stylesheet's colors.
- `sync_font`: use Pearl's explicit family and logical pixel size. When the
  family is empty, retain the Qt platform's family and synchronize the size;
  establish the exact QFont serialization and DPI behavior in Q1/Q3.
- Empty `icon_theme` leaves that key unmanaged. A selected theme is checked for
  availability, with missing-icon fallback behavior included in testing.
- Null `corner_radius` leaves that option unmanaged. An explicit value is
  bounded by the supported Darkly version; the inspected schema uses 1–16.
- `sync_reduced_motion` maps Pearl's reduced-motion preference to verified
  Darkly animation options. Density synchronization is opt-in; four KDE focus
  color keys are synchronized by default while management is enabled.
- A missing target dependency produces per-target status; it does not prevent
  the other installed Qt version from working or prevent Pearl from starting.

Old configuration files continue to load with management disabled. Older Pearl
binaries reject the added object under their strict parser; document removing
the object after restoring management when downgrading. Validate omitted fields,
unknown keys, duplicate keys, nullable values and limits explicitly.

The candidate Darkly option mapping comes from its
[configuration schema](https://github.com/Bali10050/Darkly/blob/main/kstyle/darkly.kcfg).
Pin and test the supported upstream revision in Q1 before treating those keys as
a compatibility contract.

### Files and ownership

Paths below are relative to `$XDG_CONFIG_HOME`, normally `~/.config`.

| Path | Ownership and purpose |
| --- | --- |
| `pearl/qt/palette-5-<hash>.conf` | Immutable generated Qt 5 palette |
| `pearl/qt/palette-6-<hash>.conf` | Immutable generated Qt 6 palette |
| `pearl/qt/{qt5,qt6,darkly,kde}.json` | Original presence/value, last write and bounded interrupted-write recovery state |
| `pearl/qt/writer.lock` | Nonblocking writer lease |
| `qt5ct/qt5ct.conf`, `qt6ct/qt6ct.conf` | Patch only the supported style, palette, font and icon keys |
| `darklyrc` | Patch only selected, verified options |
| `kdeglobals` | Four optional Darkly focus/hover/negative/background keys |
| `pearl/qt/session.conf` | Fixed marker consumed by the direct login and UWSM hooks |

Treat generated files as Pearl-owned and external files as shared. Preserve
unrelated sections, keys and comments. Capture whether a managed key was absent
before enabling, so restore can delete an introduced key rather than invent a
default. Releasing ownership of a field follows the same restore rules as
disabling the feature.

On external modification of a managed key, stop updating that target and report
a conflict. Offer a concrete comparison and an explicit reapply action through
Settings. Restore only keys still equal to Pearl's last-written value. Preserve
conflicting edits and report any incomplete restoration. Do not restore whole
files over new unrelated settings.

Validate paths and file types, including parent-directory traversal, before
mutation. Symlink-managed dotfiles are reported as unsupported in the first
release instead of being replaced. Use existing atomic replacement primitives
where applicable; add meaningful race and recovery tests for the new boundary.

### Apply, retry and recovery

Prepare a typed Qt change set with the candidate palette. Draft previews never
write external settings. After preference persistence and successful appearance
installation, queue reconciliation for that committed revision. Inspect the
current service's persist/completion ordering before adding side effects.

Publish immutable palette files before pointing qtct at them. Compare and patch
external files, recording each completed operation durably. Multiple external
files do not form one atomic transaction: expose partial results honestly and
use idempotent reconciliation to finish or restore them. Never notify applications
of success before the required files for that target have been published.

A Qt integration failure does not undo a successful Pearl preference save. Track
`desired_revision`, `applied_revision`, target results, conflicts, and whether
application restart or login restart is needed separately from `export_error`.
An explicit retry reconciles the latest committed revision, never an old draft.
Serialize writers and discard obsolete queued work. On startup, reconcile an
incomplete journal with observed bytes; preserve edits that cannot be attributed
to Pearl. Recovery from `last-good.json` alone must not enable new external writes.

Use event-driven work. Avoid repeated subprocess probing, a theme polling timer,
or wallpaper regeneration solely because a Qt setting changed. Keep generated
palettes referenced by active config or recovery records; bound all other retained
generations and transaction history.

## Deliverable sequence

Each milestone should produce a reviewable change, its relevant tests, and a
short evidence record under `artifacts/qt-darkly/qN/`. Checkpoints are deliverable
boundaries, not automatic requirements to stop for user permission.

| Step | Deliverable | Dependencies | Completion gate |
| --- | --- | --- | --- |
| Q1 | Verified Darkly/qtct compatibility contract and Qt fixtures | None | Both Qt versions load Darkly and a custom palette in isolation |
| Q2 | Preference model and integration status contract | Q1 | Strict parsing, defaults, merge and transport round trips pass |
| Q3 | Qt palette, font and Darkly option adapters | Q1–Q2 | Actual Qt consumers read generated values correctly |
| Q4 | Protected external configuration and restore engine | Q2–Q3 | Conflicts, partial failure and crash recovery preserve user edits |
| Q5 | Session activation and dependency diagnostics | Q1, Q4 | Supported launch paths inherit the selected integration |
| Q6 | Commit reconciliation and update notification | Q3–Q5 | Apply, retry and restart behavior are verified end to end |
| Q7 | Appearance UI and native first-release acceptance | Q2, Q6 | Users can enable, edit, inspect and disable management |
| Q8 | Darkly density and additional appearance controls | Q7 | Supported geometry/motion mappings pass visual checks |
| Q9 | Qt Quick, KDE and Flatpak compatibility extension | Q7 | Tested support boundaries and optional adapters are delivered |
| Q10 | Packaging, documentation and release acceptance | Q7; Q8–Q9 for extended release | Clean install, upgrade, restore and release checks pass |

### Q1 — Establish the actual integration contract

Deliver a compatibility document with pinned source/package versions, supported
Darkly builds, qtct plugin keys and config layouts. Use the
[current qt6ct upstream](https://www.opencode.net/trialuser/qt6ct) when pinning;
the older GitHub mirror is archived.

Build small Qt 5 and Qt 6 widget fixtures with a common control gallery and a
machine-readable report of style identity, effective palette roles, font and
icon theme. Test dependencies may use C++/Qt without entering the shell binary.
Check whether an optional separate runtime probe is required to distinguish
an installed plugin from one that can actually load.

Verify a shared `QT_QPA_PLATFORMTHEME` selection for both runtimes, including
whether the installed Qt 6 plugin accepts the `qt5ct` alias. Do not assume
`qt6ct` loads in Qt 5 or rely on untested semicolon fallback behavior. If no
common selection works, settle a tested launch strategy before Q5.

Determine the exact palette format and role count for each supported runtime,
the qtct reload mechanism for an atomically replaced config, and whether changing
only a referenced palette file is observed. Probe Darkly option reload separately.

**Acceptance:** isolated light/dark fixtures demonstrate Darkly actually loaded,
custom colors applied and a documented reload/restart result for each runtime.
Missing plugins and incompatible builds have reproducible negative cases.
Record unresolved issues as explicit blockers for dependent work.

### Q2 — Add preferences and a typed status model

Implement the `qt` preference object, validation and documented defaults. Keep
schema and serialization consistent across the backend, Advanced editor and
full Settings client. Extend existing draft/merge tests to cover independent
Qt edits, overlapping edits and upgrades from configurations without `qt`.

Define per-target capabilities and results: disabled, missing dependency,
ready, applying, applied, conflict, failed, and restore incomplete. Keep restart
requirements as separate fields rather than pretending a written config proves
an application adopted it. Bound results for the control protocol and use the
existing Settings document transfer for larger conflict reports.

**Acceptance:** all defaults and round trips pass; opening Settings causes no
external writes; older preference fixtures remain valid; malformed settings and
oversized diagnostics cannot bypass existing limits or discard a draft.

### Q3 — Implement deterministic theme adapters

Add proposed modules `src/theme/qt_palette.zig` and `src/theme/darkly.zig`.
Generate complete Active, Inactive and Disabled palette groups. Start with:

| Qt role | Pearl source |
| --- | --- |
| Window / WindowText | `surface` / `text` |
| Base / AlternateBase | `low` / `container` |
| Text / ButtonText | `text` |
| Button | `high` |
| Highlight / HighlightedText | `primary` / `on_primary` |
| ToolTipBase / ToolTipText | `high` / `text` |
| Link / Accent where supported | `primary` |
| PlaceholderText | Derived from `secondary` and the actual background |
| Light, Midlight, Mid, Dark, Shadow, visited links | Explicit deterministic derivation, checked against each background |

Document remaining roles and state derivation instead of depending on positional
guesses. Test readable disabled states, inactive selections, focus indicators and
links. Emit Qt 6's newer roles only for consumers whose format supports them.
The [QPalette API](https://doc.qt.io/qt-6/qpalette.html) defines the role/group model.

Use the Qt fixture to validate serialized font values and logical pixel sizing
at different scale factors. Generate a bounded Darkly patch for radius and
reduced motion; retain focus indicators and keyboard navigation cues.

**Acceptance:** static light/dark and several generated palettes pass role and
contrast checks, then render correctly in the real fixtures. GTK-mode fallback
is deterministic. Escaped font names and missing fonts/icons have tested results.

### Q4 — Build the configuration ownership and restore engine

Add proposed `src/config/qt_integration.zig` and focused shared INI patch support.
Read only the supported QSettings/KConfig subset; preserve unknown content and
reject ambiguous managed sections, duplicate managed keys or unsupported syntax.
Capture initial values and create immutable palette generations and a durable
operation record before replacing external settings.

Implement per-key comparison, atomic file replacement, writer serialization,
bounded journals, explicit retry and conditional restore. A crash between an
external replacement and updating the ownership record must be recoverable by
comparing the recorded before/after content. Check cancellation at safe boundaries.

**Acceptance:** test existing and missing files, absent keys, unrelated edits,
managed-key conflicts, concurrent writes, permissions, invalid paths, symlinks,
full-disk/write failure and interruption between each persistence step. Repeated
apply is a no-op; disable restores eligible original values while preserving
subsequent edits. No path outside the documented targets is modified.

### Q5 — Integrate session startup and dependency detection

Implement the selection established in Q1 before ordinary applications start.
Cover the supplied UWSM path and the authenticated Pearl session wrapper. Keep
pre-login greeter initialization separate. The existing environment reader in
`src/services/session_environment.zig` reads a session ID; it is not a mechanism
for changing another process's environment.

Test direct child launches, GIO desktop launches, D-Bus activation, systemd user
launches and compositor shortcuts. Scope any environment-manager integration to
the real session startup path. Enabling management mid-session may require a new
login to cover every launch path; show that requirement rather than claiming
Pearl can change its parent's or every terminal's environment.

Handle conflicting style overrides and other platform plugins without silently
replacing unrelated session settings. Dependency refresh occurs at startup,
explicit refresh or relevant settings entry; cache results. Disabling management
restores owned persistent assignments, with honest logout requirements for
already inherited environment values.

**Acceptance:** fixture reports from every supported launch path agree after a
fresh login. Existing overrides and missing Qt 5/6 plugins produce useful status.
Private tests leave host configuration and the host activation environment intact.

### Q6 — Connect Apply to reconciliation and reload

Integrate Q4 with `src/config/service.zig` using the committed revision lifecycle.
Use immutable prepared data and a serialized external writer; never block the
GTK main thread on configuration I/O or plugin probing. Distinguish a successful
Pearl save from failed or pending external application updates in Settings/CLI.

Publish the qtct config changes that Q1 proved sufficient to refresh palettes.
Emit the tested Darkly configuration notification only after its writes complete.
Upstream listens for `reparseConfiguration` on `/DarklyStyle` with interface
`org.kde.Darkly.Style`; that signal is evidence of an option reload path, not a
guarantee that qtct rereads its palette. See the
[Darkly implementation](https://github.com/Bali10050/Darkly/blob/main/kstyle/darklystyle.cpp).

Avoid notifications for unchanged output. Apply startup/session authority and
lock checks to retries and restores. Reconcile an interrupted valid transaction
when authority is available; do not run a permanent retry loop on conflicts.

**Acceptance:** static changes, wallpaper changes, rapid successive commits,
failed generator, failed save, target failure, lock, disconnect and process restart
all leave accurate status. Test existing and newly launched apps independently.
No stale palette wins over a later commit; idle has no recurring theme work.

### Q7 — Deliver the native Appearance workflow

Add a Qt applications card to full Appearance with management toggle, Darkly
identity, Qt 5/6 availability, palette mode, font sync, icon selection, optional
radius and reduced-motion sync. Show the GTK fallback when relevant. Use the
existing global draft footer for preference edits.

Provide status details with changed targets and restart guidance, a retry action
for the current committed settings, and a conflict comparison before reapplying
managed keys. Disable-and-Apply invokes conditional restoration; expose incomplete
restore results. Keep those repair operations separate from unsaved draft edits.

Use a real Qt fixture for optional preview with a private temporary config and
child-only environment. Do not represent a GTK mockup as a Darkly render. Preview
closes cleanly and cannot publish configuration to the user's apps.

**Acceptance:** enable → Apply → launch Qt app → change colors → disable works
from the UI. Cover draft retention/discard, external preference edits, locked
session, backend loss, failed restore and target-specific errors. Verify keyboard
navigation, accessible labels, English/German text, light/dark Pearl modes and
narrow windows. This is the native first-release feature gate.

### Q8 — Extend Darkly appearance controls

Measure Darkly's button/menu/tab geometry and add a documented normal/compact
mapping only where the pinned schema supports it. Verify control bounds and
click targets at 100%, 150% and 200% scale. Preserve users' options that Pearl
does not manage, including application-specific exceptions.

If exposing animation duration or additional geometry, add each option through
the schema, ownership engine and shared draft UI. Opacity/blur requires separate
Aqueous compatibility evidence before exposure; do not infer that a KWin effect
works on Aqueous.

**Acceptance:** before/after screenshots and measured fixture geometry support
every exposed control. Reduced motion includes busy indicators and transitions.
Resetting an override relinquishes its key without damaging other Darkly settings.

### Q9 — Deliver broader application compatibility

Create a published matrix for a plain Qt Quick Controls application, a
Kirigami/KDE application, Dolphin, Kate and a representative KDE-runtime Flatpak.
Record exact application/runtime versions, effective style/palette, live-update
behavior and required restarts. App editor/document colors are separate from
widget appearance; do not silently rewrite application-specific themes.

For KDE consumers that need additional color configuration, establish whether a
supported qtct build suffices. If `kdeglobals` synchronization is necessary, add
it as a separately documented, optional set of owned color keys using Q4 rather
than taking ownership of the whole file.

Qt Quick can select styles independently of Qt Widgets, including at compile
time. Test platform palette inheritance and any optional integration against real
apps. Do not set `QT_QUICK_CONTROLS_STYLE=Darkly` without an actual compatible QML
style. See [Qt Quick styling](https://doc.qt.io/qt-6/qtquickcontrols-styles.html).

Flatpak support needs a Darkly extension matching each supported KDE runtime,
access to the intended settings, and tested activation within the sandbox.
Package/detect extensions and use narrowly scoped, reversible per-app integration
where needed. Maintain a separate installed-versus-applicable status. Upstream
documents runtime and reload limitations in its
[Flatpak instructions](https://github.com/Bali10050/Darkly#flatpak).

**Acceptance:** every matrix row is marked verified, partial or unsupported with
evidence and a specific reason. Optional adapters have restore tests. A future
Settings portal bridge for dark/light and accent preferences is a separate
desktop integration project, not a prerequisite for native Darkly support.

### Q10 — Package and release

Update stable and Git package metadata with verified Darkly/qtct runtime package
names and optional descriptions. Any runtime probe is packaged separately from
the shell's GTK dependencies. Pin versions in the compatibility record; do not
run upstream installer scripts as package-install side effects.

Install session support through the existing packaging workflow. Test disabled
clean install, enabled upgrade, missing dependency, restore, removal guidance and
re-enable. Preserve recovery data until restoration is complete; a package removal
must not erase the information needed to recover original settings.

Update `PREFERENCES.md`, `COMPATIBILITY.md`, `DEVELOPMENT.md`, `RELEASE.md` and
`PROGRESS.md`. Document account-wide file scope, supported session startup paths,
GTK fallback, live-update limits, optional Flatpak support and downgrade procedure.

**Acceptance:** staged packages pass applicable release checks; native release
requires Q1–Q7, while extended Darkly/compatibility claims also require Q8/Q9.
Record physical-desktop checks separately from headless automation. No skipped
required dependency test is counted as a pass.

## Verification and evidence

Add proposed `test-qt-theme-unit` and `test-qt-theme` build targets. Unit tests
exercise adapters and ownership decisions; integration tests run actual Qt
consumers on private Aqueous with isolated HOME/XDG directories and session bus.
Extend the harness explicitly for XWayland tests: its current private session
starts Aqueous with `-no-xwayland`.

Mandatory matrix: Qt 5/6 × light/dark × static/dynamic; selected edge cases cover
GTK fallback, active/inactive/disabled widgets, missing dependencies, external
edits, fresh/existing apps, scale changes and each supported launch path.
Use programmatic effective-value assertions alongside screenshots, because a
similar-looking fallback style can otherwise hide a failed Darkly load.

Run existing checks relevant to each touched boundary, including:

```sh
zig build test -Doptimize=ReleaseSafe
zig build test-preferences -Doptimize=ReleaseSafe
zig build test-settings-appearance -Doptimize=ReleaseSafe
zig build test-settings-boundary -Doptimize=ReleaseSafe
zig build test-settings-integration -Doptimize=ReleaseSafe
zig build test-release-tools -Doptimize=ReleaseSafe
zig build test-release -Doptimize=ReleaseSafe
```

Use [the private development environment](DEVELOPMENT.md) and run additional
session/greeter regression checks when their startup paths change. A docs-only
plan update needs link and whitespace checks, not application test execution.

Each milestone evidence record includes the revision, toolchain/package versions,
commands and exit results, effective Qt state, relevant screenshots, known gaps
and its acceptance decision. Real-login, mixed-DPI and screen-reader results must
identify whether they were physically tested or remain pending.

## Main risks and completion criteria

| Risk | Required resolution |
| --- | --- |
| Qt 5 and Qt 6 select different platform plugins | Verify a shared selection or a complete launch strategy in Q1 |
| qtct and KDE consumers disagree on palette source | Test effective roles and isolate optional KDE key synchronization in Q9 |
| Reload signal fires but an application keeps old colors | Assert actual widget state; report restart requirements |
| Shared configuration changes outside Pearl | Per-key ownership, conditional restore and conflict reporting |
| Crash leaves only some files updated | Durable operation records and idempotent reconciliation |
| Font size changes with toolkit/DPI interpretation | Round-trip through QFont and render at multiple scale factors |
| Darkly options or palette formats change | Pin supported versions and maintain versioned fixtures |
| A nested session affects the host desktop | Private files/bus, no host manager import, isolation assertions |
| Darkly is absent inside a sandbox | Runtime-specific extension detection and scoped compatibility status |

The native feature is complete when supported Qt 5/6 applications demonstrably
use Darkly and Pearl's selected palette/font, changes and failures have accurate
status, disable/restore preserves user edits, and a clean packaged login behaves
the same as the private integration tests. Broader compatibility is complete only
for the application/runtime combinations explicitly verified in Q9.
