# Custom launcher identity and dock pinning — issue #3

Status: explicit launcher-choice fix implemented, 2026-09-19. This replaces the
initial investigation plan. Automatic attribution remains a separate follow-up.

The additional matching and pinning fix is implemented in the
[Pearl-only preferred-launcher plan](DOCK_LAUNCH_ATTRIBUTION_PLAN.md), revised after
native reinvestigation on 2026-09-24. The separate
[Aqueous attribution proposal](AQUEOUS_LAUNCH_ATTRIBUTION_PLAN.md) is deferred and
is not required for that fix. This document continues to describe the implemented
manual-choice behavior.

The implementation uses `app_identity.zig` for stable keys and atomic list/pin
changes, shared matching in `task_apps.zig` / `task_model.zig`, a manager-owned
native picker, and a Settings removal list. The resolver retains unavailable
explicit IDs using an `available` flag; association hashes invalidate snapshots.
The picker incrementally presents 50 catalog entries at a time and has a
scrollable viewport for small displays.

[Native acceptance and regression results](../artifacts/dock-desktop-overrides/README.md)
cover pin correction, custom icons/arguments/actions, restart, reset, stale
callbacks, hidden/removed selections and Settings Apply/Discard. Wayland is
verified end to end; XWayland identity policy has unit coverage, while native
XWayland presentation remains unqualified. The design below records the intended
contract and implementation sequence.

Issue: [Pearl dock using wrong icon for custom .desktop](https://github.com/Seafoam-Labs/pearl/issues/3).
[Reproduction evidence](../artifacts/dock-desktop-overrides/README.md) includes
native screenshots, launch records, and eight completed cases.

## Decision and scope

Implement a remembered **Use launcher…** choice for a running application.
Selecting a custom desktop entry makes its icon, name, desktop actions, and
future pinned launches agree. The choice applies to windows with the selected
application identity and survives Pearl restarts. Allow correcting an existing
packaged pin in the same operation.

This implementation explicitly requires one user selection for a
custom entry with a different desktop ID. It does not claim to recover the
original launcher automatically. Automatic launch attribution is a separate
follow-up described below; it must not be advertised as delivered by this fix.

Preserve existing GIO discovery, rendering, and execution. Same-ID user overrides
already work at startup, after live edits and atomic replacement, and after
removal. No custom XDG scanner or icon renderer is warranted by the evidence.

## Confirmed cause and available information

The reproduced custom entry is `CustomOverride.desktop`, but its window reports
`org.pearl.Override`. `task_model.matches` matches that window to the packaged
`org.pearl.Override.desktop`. `task_apps.match` returns that ID; the dock uses it
for the icon, menu, and saved pin. Later GIO correctly launches the saved packaged
ID. Explicitly pinning `CustomOverride.desktop` already uses its custom arguments.

Pearl's `aqueous.entities.Window` exposes backend, app ID, class and opaque window
ID, but no process ID, startup token or originating desktop ID. Aqueous's local
`Window.unreliablePid()` can obtain a PID, but `ShellManager` does not publish it
in the window snapshot. A PID would still need careful correlation for wrappers,
process reuse, sandboxed applications and D-Bus activation.

Consequently, an arbitrary external custom launch cannot be identified reliably
from today's window data. Recent-launch order, executable-name similarity and a
preference for any user-local file would misidentify other applications or
profiles. Keep unresolved cases conservative.

The reporter's exact filenames and desktop contents are still unknown. This
plan addresses the demonstrated distinct-ID case; a same-ID report would require
another reproduction before changing the diagnosis.

## Behavior contract

| Situation | Result |
| --- | --- |
| No saved choice | Existing unique desktop-ID / StartupWMClass matching remains unchanged |
| User chooses a custom launcher | All windows with that exact identity use the selected desktop ID for presentation and grouping |
| Pin an associated running group | Save the selected desktop ID, then relaunch through that entry after the app closes |
| Change the launcher of a pinned running group | Replace that group's pin and save the association atomically; retain its position unless the target is already pinned |
| Explicit custom pin | Keep its identity; associated windows join that pin instead of creating a packaged running group |
| Packaged and custom pins intentionally coexist | Only the selected launcher receives windows matching the saved identity; the other remains independently launchable |
| Selected entry edited | Catalog generation refresh updates its name, icon and actions; next launch resolves the current entry |
| Selected entry removed or hidden | Retain the choice and pin, show an unavailable launcher, and allow Change, Reset or Unpin; do not silently launch the packaged entry |
| Entry reinstalled with the same ID | Resume using it when GIO reports it available |
| Reset to automatic | Remove the association; preserve explicitly saved pins and return running-window matching to the existing rules |
| Missing stable app ID/class | Disable persistent association with a concise explanation; keep existing per-window controls |

Choosing a launcher does not execute it or modify any `.desktop` file. Keep
launch validation, GIO quoting/field codes, working directory, terminal and D-Bus
behavior. The initial **Use launcher…** control explains that the choice applies
to all windows of that application, including separately launched profiles that
report the same identity. Per-process profile separation is outside this fix.

## Data and matching design

Add a default-empty `application_launchers` collection to `Preferences`:

```json
{
  "application_launchers": [
    {
      "backend": "xdg",
      "identity": "org.pearl.Override",
      "desktop_id": "CustomOverride.desktop"
    }
  ]
}
```

Use exact, case-sensitive identities: nonempty Wayland `app_id` for `xdg`, and
nonempty XWayland `class` for `xwayland`. Backend is part of the key. Do not derive
keys from window titles, strip identity suffixes, or persist opaque window IDs.
Allow multiple identities to select one desktop entry; reject duplicate keys.
Bound the collection to 128 records, identities to 1024 bytes of valid UTF-8
without NUL/control characters, and desktop IDs to the existing pin validator.
Do not store executable commands or absolute desktop-file paths.

Retain `pinned_apps` as its current ordered ID list. Existing preference files
load with an empty association list. Follow the repository's version-1 additive
field convention; document that older strict parsers require removing the new
field before downgrade. Cover serialization, editor transport, validation,
backup/recovery, and merge behavior. Keep the new list atomic in the existing
three-way merge: simultaneous differing edits produce a visible conflict.

Introduce a pure resolver returning one of:

- `selected`: explicit association, effective desktop ID and available entry;
- `selected_unavailable`: explicit association and missing/filtered entry;
- `automatic`: the existing unique match;
- `unmatched`: existing missing/ambiguous fallback behavior.

An explicit association wins before automatic matching. A missing explicit
selection remains distinguishable from an absent choice, so automatic fallback
cannot silently change its launch command. Carry the selected ID into group
keys even while its entry is unavailable. Use a generic icon and a visible
unavailable label in that state; window activation still works.

Resolve once through shared policy used by the dock and global running-app
snapshot. Include an association revision in snapshot early-return checks and
invalidation, in addition to Aqueous model and catalog generations. An unrelated
appearance edit should not rebuild identity state. Retain copied IDs and owned
snapshot data, with no catalog pointers surviving a refresh.

## Implementation sequence

### 1. Pure association model and persistence

Add `src/desktop/app_identity.zig` for stable keys, association validation and the
pure resolution result. Extend `src/config/preferences.zig` with the collection.
Wire the resolver into `task_model.zig`; have `task_apps.zig` adapt the GIO catalog
and supply the same policy to both consumers instead of duplicating selection.

Add focused tests for exact backend/identity matching, explicit precedence,
missing selections, duplicate/invalid keys, multiple identities sharing one
launcher, and unchanged automatic ambiguity. Update preference/merge tests for
round trips, old files, conflicting edits and recovery.

**Exit criterion:** the reproduced window resolves to `CustomOverride.desktop`
when its association is present, and to the packaged ID when no association is
present. Removing the selected desktop entry does not produce an automatic match.

### 2. Apply resolution to grouping, icons and actions

Update `task_apps.Store`, `task_model.Snapshot`, `dock.zig`, and
`ui/surfaces/manager.zig` to pass committed associations and their revision.
Group associated windows under the selected ID on every output and in the global
running-app widget. Preserve output filtering, window cycling, stable ordering,
selection by window ID, counts and existing overflow behavior.

Dock names, icons, **Open new window**, desktop actions and **Pin to dock** must
all use that selected ID. Keep activation by current opaque window ID separate
from launching. Resolve an entry again through GIO immediately before launching;
validate visibility and action existence. Keep unavailable pins actionable for
repair/unpinning, but disable launch and desktop actions.

Test changing an association while a chooser or dock menu is open. Preserve the
dock's deferred rebuild until menu closure. Revalidate callbacks against the
current association: a stale launch or pin action must report changed state
instead of acting on the old packaged ID. Existing window-focus actions remain
valid only while their window still exists and is eligible.

**Exit criterion:** a selected custom launcher supplies both the running icon and
idle pin; all windows remain reachable through updates and selection changes.

### 3. Native launcher selection and atomic pin correction

Add **Use launcher…** to the context menu of running groups with a stable
identity, including ambiguous/unmatched groups. Implement a searchable native
picker in `src/desktop/launcher_picker.zig`, using the existing shared catalog's
base application entries only. Show icon, application name and desktop ID so
identically named profiles can be distinguished. Mark the current selection;
provide **Use launcher** and **Reset to automatic**. No command editor is needed.

Present the picker through the manager's keyboard-capable popup surface. Close
the dock popover before handing off input; preserve the originating output and
copy the requested window identity. Add an explicit event/pane and manager-owned
lifetime, with the same lock, disconnect, output-removal and Escape handling as
other shell popups. Search must be bounded/virtualized and keyboard accessible.
Catalog refresh preserves selection by desktop ID; confirmation revalidates it.

When the initiating group is pinned, explain that applying the choice also
updates its pin. Submit one preference transaction that changes the association
and replaces the source pin in place. If the target ID is already pinned, retain
that target's existing position and remove the replaced source to avoid
duplicates. For an unpinned group, save the association without automatically
pinning it. Subsequent **Pin to dock** uses the selected ID.

Revalidate the initiating identity, association, catalog entry and preferences
revision before applying. If a concurrent edit changes these, refresh and show
the conflict; do not overwrite newer choices. Failed persistence leaves both
live grouping and pins unchanged. Do not destroy picker callbacks while an
accepted transaction is completing.

Add a small **Application launchers** list to Settings → Bar & dock using the
existing preference draft. Display the application identity and selected desktop
ID, and support removing a choice even when no window or pin remains. Settings
Apply/Discard and external dock edits use the existing merge/conflict flow.
Audit editor/backend serialization so opening and saving Settings preserves the
new collection. Reuse selected catalog metadata where available, but do not make
removal dependent on the application still being installed.

**Exit criterion:** reproduce the original failing sequence, select the custom
entry through the real UI, pin it, close it and relaunch with the custom icon and
arguments. Correcting an already packaged pin works without manual JSON edits.

### 4. Turn the reproduction into an acceptance gate

Retain `reproduce_desktop_overrides.py` and its original evidence as the baseline.
Create `test_desktop_overrides.py` and a `test-desktop-overrides` build target for
post-fix assertions. Do not count the baseline's expected packaged launch as a
passing fix: the new test must explicitly assert the chosen custom ID and args.

| Acceptance case | Required evidence |
| --- | --- |
| External launch from differently named entry; choose custom, pin, close, relaunch | Saved association and custom pin, green native icon, custom desktop path and arguments |
| Existing wrong packaged pin corrected | One atomic commit, stable pin order, custom actions and arguments |
| Target already pinned / both pins coexist | No duplicates or unintended pin deletion; grouping follows the explicit choice |
| Pearl restart and two outputs | Association and pin persist; dock and global task widget agree |
| Two profiles with the same app identity | Documented identity-wide choice; no last-launched-wins heuristic |
| Same-ID user overrides | All current startup/edit/replace/remove checks continue to pass |
| Selected entry removed, hidden, reinstalled | Unavailable state preserves choice; no packaged launch; recovery by same ID works |
| Reset from dock and Settings; Apply/Discard/conflict | Predictable automatic matching and unchanged explicit pins; no lost edits |
| Catalog edit or association change while menu is open | Stale actions rejected; no stale callback or unexpected executable |
| No stable identity, duplicate StartupWMClass, XWayland class | Appropriate disabled selection or deterministic shared resolver behavior |
| Keyboard, lock, disconnect and output removal | Picker dismisses safely and releases input |

Use rendered icon assertions and the existing fixture's launched desktop-file
marker and argument log. Cover base launch, **Open new window**, and at least one
custom desktop action. Keep GIO D-Bus/terminal semantics in existing desktop
regressions. Use an isolated XWayland-enabled fixture for end-to-end class checks;
the current reproduction starts Aqueous with XWayland disabled.

Run after implementation:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
zig build test-desktop-overrides -Doptimize=ReleaseSafe
zig build test-dock-islands -Doptimize=ReleaseSafe
zig build test-desktop -Doptimize=ReleaseSafe
zig build test-running-apps -Doptimize=ReleaseSafe
zig build test-preferences -Doptimize=ReleaseSafe
zig build test-settings-bar-editor -Doptimize=ReleaseSafe
```

The focused target is new work. Record post-fix results separately under
`artifacts/dock-desktop-overrides/fix/`. Update `docs/DOCK_ISLANDS.md`,
`docs/DESKTOP.md`, and `docs/PREFERENCES.md` with selection/reset behavior and the
same-ID versus distinct-ID distinction. Report the explicit-selection fix as
complete only after these gates pass; do not claim automatic origin detection.

## Automatic attribution follow-up

If automatic preservation is required, expand the scope before implementation:

1. Define an Aqueous/Pearl contract carrying optional launch correlation metadata
   on windows. Assess process identity and startup/activation tokens together;
   `Window.unreliablePid()` alone is not an authoritative desktop-file identity.
2. Preserve the exact desktop ID for launches from Pearl's launcher and dock
   using GIO launch-context signals. Correlate only with supported compositor
   evidence. GIO's launch PID can be zero or absent, especially with D-Bus.
3. For external launches, prove a bounded method to recover the original entry,
   such as validated process launch markers, without treating inherited markers
   as proof for arbitrary descendants. Validate process ownership/start time,
   canonical effective desktop ID and current availability. Do not log process
   environments or execute desktop-file paths recovered from them.
4. Exercise wrappers, Flatpak, D-Bus activation, reused processes, two simultaneous
   profiles, delayed windows, Pearl restarts and old Aqueous versions. Keep the
   explicit chooser when correlation is unavailable or ambiguous.

Automatic support needs its own protocol fixtures, compatibility documentation
and acceptance gate. The remembered user choice remains authoritative when it
exists. Neither a last-launch timestamp nor an executable-name match is an
acceptable replacement for that contract.

## References and implementation basis

- `src/desktop/task_model.zig`, `task_apps.zig`, `dock.zig`: current matching,
  grouping, callbacks, pins and GIO launch validation.
- `src/desktop/apps.zig`, `launcher.zig`, `running_apps.zig`: shared catalog,
  launch path and other consumers of application identity.
- `src/aqueous/entities.zig`: current window metadata available to Pearl.
- Local Aqueous `compositor/aqueous/Window.zig` (`unreliablePid`) and
  `ShellManager.zig` (published window snapshots): automatic-attribution gap.
- `src/config/preferences.zig`, `merge.zig`, `settings/preference_pages.zig`:
  persistence, conflict handling and Settings integration.
- [Desktop-file IDs](https://specifications.freedesktop.org/desktop-entry/latest/file-naming.html),
  [GIO desktop lookup](https://docs.gtk.org/gio-unix/ctor.DesktopAppInfo.new.html),
  and [GIO launch behavior](https://docs.gtk.org/gio/method.AppInfo.launch.html):
  retain the existing standard resolution and execution semantics.
