# Issue #3: preferred custom launchers — Pearl-only fix plan

Status: implemented in Pearl, 2026-09-24. Native acceptance covers automatic
preferences, custom arguments/icons, stale menus, and spaces/Unicode in desktop
IDs. See [validation](../artifacts/dock-desktop-overrides/preferred-fix/README.md).

Issue: [Pearl dock using wrong icon for custom .desktop](https://github.com/Seafoam-Labs/pearl/issues/3).

## Decision

Implement launcher preference and matching in Pearl. No Aqueous changes are needed
for the reproduced matching and pinning defects. The earlier compositor attribution
design addressed a broader question: which launch produced each individual window.
That is not necessary to let users choose a preferred launcher for an application.
The separate Aqueous plan is deferred and is not a dependency of this fix.

Keep GIO desktop discovery and launching, the existing `application_launchers`
preferences, and **Use launcher…**. Do not add process inspection, launch tokens,
launch registration, or a new persistent preference format.

## Evidence from reinvestigation

[Retained observations](../artifacts/dock-desktop-overrides/reinvestigation/results.json)
come from a private native Aqueous session using the unchanged Pearl integration
build. The runner records current behavior, including failures; it is not a passing
fix gate. See [reproduction instructions](../artifacts/dock-desktop-overrides/reinvestigation/README.md).

| Setup | Observed behavior | Implication |
| --- | --- | --- |
| Same-ID user override, SVG icon with spaces in its path | Correct custom icon, custom arguments, one dock group | GIO precedence and this SVG rendering path already work |
| Differently named custom pin, no matching StartupWMClass | Custom arguments launch, but a separate packaged running group appears | Launch execution is correct; the window lacks a link to the custom entry |
| Custom entry declares the window's StartupWMClass; packaged entry also matches | Running group is unmatched and has a generic icon | Pearl rejects all duplicate matches without a preference policy |
| Same matching custom entry is pinned | Still unmatched; idle custom pin plus separate running group | Matching ignores the saved pin even when it is a valid candidate |
| `Custom Override.desktop` | GIO accepts it; Pearl CLI rejects it | Pearl's desktop-ID validator excludes real discoverable launchers |

The earlier six same-ID baseline cases and all 13 manual-choice acceptance cases
also passed. These results do not prove the reporter's exact application works:
its desktop filenames and contents have not been identified, and no live Pearl
session was available during reinvestigation.

## Scope and limits

The product policy is **one preferred launcher per application identity**. It can
apply equally to externally launched windows because app ID/class is already in
the Aqueous snapshot. It does not claim to recover the originating launch or split
two profiles that report the same identity.

A differently named entry with neither a matching desktop ID nor StartupWMClass
contains no reliable link to the window. Preserve the existing **Use launcher…**
choice for that case. Merely installing or launching an unrelated custom entry
must not make Pearl associate the next window with it. Users can also use a true
same-ID override or declare the correct StartupWMClass in a distinct launcher.

## P1 — shared preferred-launcher resolution

Use one pure selection policy for the dock and global running applications.
First honor the existing explicit association, including its unavailable state.
Otherwise build candidates from the existing exact desktop-ID stem and
StartupWMClass comparisons against the window app ID/class, then apply:

1. If exactly one candidate is pinned, select it. More than one matching pin is
   ambiguous and requires the existing chooser.
2. With no matching pins, if exactly one candidate comes from the user's XDG
   applications directory, select it. Multiple matching user entries are ambiguous.
3. With no matching pins or user entries, retain the existing unique-candidate
   result; multiple system candidates remain ambiguous.

This is a Pearl preference policy for distinct desktop IDs, not a claim
that the desktop-entry specification gives all user files precedence over all
system files. Only entries already matching the window are eligible. Document
that the policy affects all windows sharing that identity; explicit associations
remain the way to select a different preference.

Identify user entries from the effective GIO desktop filename and GLib's user data
directory, with directory-boundary checks. Respect an overridden `XDG_DATA_HOME`;
do not hardcode `~/.local/share`, scan a second catalog, compare Exec strings, or
use recent-launch timing. Let GIO decide visibility and same-ID precedence.

Changes:

- `src/desktop/task_model.zig`: pure candidate selection with pins and entry origin.
- `src/desktop/task_apps.zig`: adapt GIO metadata and delegate to the same policy;
  eliminate its duplicate selection loop.
- `src/desktop/dock.zig` and `src/ui/surfaces/manager.zig`: pass committed pins and
  choices to both consumers.
- Include pin changes in global snapshot invalidation. Copy catalog metadata into
  owned storage and retain existing catalog-generation invalidation.

Exit: a uniquely matching custom pin receives its running windows; a uniquely
matching user launcher wins over system candidates when no pin or explicit choice
selects otherwise; ambiguous peers remain selectable through the existing UI.

## P2 — accept installed desktop IDs consistently

Replace the ASCII-only desktop-ID allowlist with a shared bounded UTF-8 validator
that accepts installed IDs containing spaces and ordinary non-ASCII characters.
Keep a finite length bound compatible with persisted fields and protocol transport;
audit those bounds together. Reject empty stems, missing `.desktop` suffix, NUL,
control characters and path separators. Desktop IDs are opaque names looked up
through GIO, never shell commands or paths opened directly.

Use the same rules in preferences, associations, picker filtering, dock buttons,
CLI requests and DMS import. Check every caller of `dock_policy.desktopId`.
Availability checks remain separate so temporarily missing saved pins survive.

Exit: `Custom Override.desktop` can be selected, pinned, persisted and launched
through GIO; invalid/path inputs remain rejected throughout the same flows.

## P3 — keep icon, actions, grouping and pins in agreement

Use the effective desktop ID for the running icon/name, Pin to dock, Open new
window and desktop actions. Existing saved pins remain ordered and independently
launchable. Automatic matching must not rewrite or remove old pins; correcting an
old wrong pin continues to use the existing atomic **Use launcher…** operation.

The new resolver depends on pins as well as associations/catalog metadata.
Revalidate running-group menu callbacks against those inputs so a pin edit while
an old menu is open cannot launch or save the previously preferred entry. Preserve
existing menu lifetime and deferred-rebuild behavior. Explicit idle-pin actions
continue to target that pin's own ID.

Keep unavailable explicit choices from silently falling back. Reset to automatic
removes the explicit choice and applies the preference policy above. Same-ID
edits/removal continue to follow GIO refresh behavior.

## Acceptance

Convert the diagnostic cases into assertions for corrected behavior in
`test-desktop-overrides`; keep the baseline evidence separately. Add focused pure
resolver and desktop-ID validation tests, plus native checks for:

- Same-ID PNG/SVG/theme icons; startup, live edits, atomic replacement and removal.
- Matching custom launcher with/without a pin: correct icon, one running group,
  custom saved ID and arguments on close/relaunch; custom desktop actions too.
- Explicit choice wins over pins; pinned packaged entry wins over automatic user
  preference; multiple matching pins/user entries remain ambiguous.
- Pin changes invalidate the global task snapshot without a window-state change.
- Spaces/Unicode in desktop IDs, persistence/restart and path/control rejection.
- Hidden, removed and reinstalled entries; stale open-menu actions.
- Dock and global task widget agree across outputs and Pearl restarts.
- Distinct custom ID with no identity link: documented manual choice still works;
  do not count automatic packaged fallback as a fixed custom-launch case.

Run ReleaseSafe build/unit checks, `test-preferred-launchers`,
`test-desktop-overrides`, `test-desktop`,
`test-dock-islands`, `test-running-apps`, `test-preferences` and
`test-settings-bar-editor`. All use the current Aqueous protocol. No compositor
capability gate, new release pin, or Aqueous rollout is required.

Before claiming the original report resolved, verify the actual affected desktop
entry and running app identity. If that reveals a same-ID failure absent from these
fixtures, reproduce and fix that Pearl path rather than expanding this plan into
launch-origin tracking.
