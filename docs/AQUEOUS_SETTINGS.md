# Aqueous settings in Pearl

Open **Control center → Aqueous settings**, or run `pearlctl aqueous show`.
This replaces the existing settings application's frontend. Pearl does not launch
that application. The standalone `aqueous-config` helper remains the canonical
TOML backend; install that helper alongside Pearl. Shell appearance, including
system/installed GTK themes, remains under **Pearl settings**.

The current target is Aqueous master
`1d038dc3bafa0044d9599f8f51f84105a6a85bb3`, helper **0.8.0**, protocol 1.
Pearl discovers the helper through PATH, negotiates capabilities and always uses
`--shell none`. Older helpers can remain readable, but writes require the modern
receipt, candidate-impact and recoverable-commit capabilities.

See [capability coverage](AQUEOUS_CAPABILITY_COVERAGE.md), the
[implementation plan](AQUEOUS_MASTER_UPDATE_PLAN.md), and the concrete
[upstream dependencies](AQUEOUS_MASTER_DEPENDENCIES.md). The original
[additions request](AQUEOUS_T11_ADDITIONS.md) is historical.

## Editing and outcomes

Appearance, Layouts, Input, Keybindings, Rules and Displays are generated from the
helper's current fields. All 221 fields in the tested schema have controls; the
[field inventory](AQUEOUS_FIELD_INVENTORY.md) records their coverage. Descriptions,
select choices, numeric limits, colors and default values come from the helper.
Advanced exposes the six raw TOML files and the complete helper request JSON.
Unknown TOML settings and comments are left to the canonical backend.

Drafts belong to the service and survive closing/reopening the view. Invalid JSON
and invalid values remain editable. Raw edits are retained as you type; a raw
file and structured changes to that same file conflict and cannot be applied.
Remove one representation in Advanced to resolve that conflict. Drafts currently
survive view destruction, not a whole Pearl process restart.

**Validate** prepares a candidate without writing and without advancing the
draft's `expected_generation`. **Apply & save** validates again and sends that
original generation. Refresh reads current files without discarding the draft.
**Rebase draft** merges independent structured fields; conflicting fields,
changed raw files and changed index-based collections require manual resolution.
Refreshing/rebasing is explicit, so a newer version cannot silently replace the
base of an older edit. A draft edited while an operation runs remains retained.

The status reports these independently:

- **Canonical save:** saved, unchanged, failed, uncertain or recovery conflict.
  Pearl parses structured results even when the helper exits unsuccessfully.
  A saved configuration can have a failed reload or partial toolkit synchronization.
- **Receipt:** complete, recovered, unavailable, unknown or recovery conflict.
  Before an apply, Pearl atomically records its timestamped random operation ID,
  generation, candidate digest and exact request hash under
  `$XDG_STATE_HOME/pearl/aqueous-operations/pending.json`. A private writer lock
  serializes operations across instances. The record contains no raw configuration.
- **Reload and display commit:** their own reported states. The helper owns reload,
  display authorization, persistence and finalization. Pearl never repeats those
  side effects merely because a response was lost.
- **Toolkit synchronization:** not requested, synced, partial or unknown. Target
  reports remain visible separately from file persistence.

A lost apply reply causes an `operation-status` query, not another apply. Refresh
also queries a pending receipt after Pearl restarts. Unknown/conflicting outcomes
keep writes and reload retry blocked; discarding or rebasing a draft does not
clear that durable uncertainty. Definitive receipts resolve the record. A missing
or expired receipt remains unresolved: do not delete the record to manufacture
permission to replay a save. Canonical helper recovery must establish the outcome.
An early rejection with a complete failure receipt can resolve the operation even
before candidate bindings exist: no write, reload or display change was requested.
Pearl retains that draft and permits an explicit retry; it does not retry the write
automatically.
Unsaved editor text itself is still memory-only across process restarts.

`pearlctl aqueous status --text operation` shows the bounded stage report;
`--text review` shows authoritative candidate impact. Large snapshot/font catalogs
are omitted from the operation summary. `Validate` can report valid syntax while
an unknown semantic impact still blocks persistence. Pure comment edits can be
saved without a display lease when the helper classifies them as having no runtime
effect. Unknown effects never become a runtime-only save by assumption.

System configuration requires an explicit `"create_user_override": true` in the
draft. Multi-file backups are written by the helper below
`$XDG_STATE_HOME/pearl/aqueous-backups/<original-generation>/`. Advanced cannot
redirect that backup directory.

## Shortcut recording

Record a binding on the Keybindings page. Pearl waits for GDK's
`shortcuts-inhibited` acknowledgement before accepting a chord. Escape, page
changes, loss of inhibition, compositor unavailability, closing the view and the
30-second deadline restore shortcuts. Modifier-only presses are ignored.
The integration test checks a real Aqueous `spawn:` marker binding: it must not
run while recording, and must run again after the popup closes.

This uses Ghostty's generated GTK/GDK bindings, including
[`GdkToplevel` shortcut inhibition](https://docs.gtk.org/gdk4/method.Toplevel.inhibit_system_shortcuts.html).

## Protected display preview

The Displays page shows connected and disabled outputs, actual mode/geometry/color,
explicit versus inherited values, declaration/source precedence, advertised modes,
monitor identity and ambiguity, configured offline declarations, profiles and policy.
`store`, `test`, `preview` and `reason` are kept separate.

A placement diagram follows staged position, scale and rotation at current mode
sizes, with numeric origins and logical dimensions for keyboard and assistive use.
Position, scale, rotation, mode and mirroring use the helper's structured monitor
edits. Scalar display policies use schema controls. Canonical validation determines
whether an edit changes live or deferred output configuration. Both require a native
lease: even `store:true` and an offline-only edit do not authorize unprotected save.

**Apply & save** binds a persistent authenticated native IPC connection to the
candidate generation/digest, compositor session and display revision. Aqueous tests
and applies the candidate and owns its deadline. **Keep displays** sends one
protected helper operation; the helper authorizes, journals, persists and finalizes.
**Revert**, timeout, owner disconnect or invalidation restore the compositor-owned
baseline under its concurrency rules. The former `--display-guard` process and
output-management rollback implementation have been removed.

Current master accepts protected previews only for headless outputs. Physical,
HDR and VRR changes remain gated; mirroring depends on renderer support. The helper
has no structured mutation for enabled/primary/profile/matching/HDR properties:
those controls explain the upstream dependency and remain disabled. Advanced raw
editing is retained, with the same classification and preview gates. Pearl does not
add a TOML serializer or infer effective state from raw draft text.

## Structured collection forms

Rules expose all schema fields and options, numeric limits and an explicit Inherit
checkbox. Missing/inherited, false and zero are different. All present matchers must
match, globs are anchored and case sensitive, and first matching rule wins. Add,
update, delete and one-at-a-time moves produce a reviewable canonical request.
Unsaved additions remain selectable and can be edited, reordered or removed before
persistence; their local draft indices are never sent as backend identities.

Custom shortcuts expose chord and compositor command syntax plus an acknowledged
recorder. Editing a spawn command never executes it; Validate reports collisions.
Named snap layouts expose IDs/names/padding, default selection and ordered zones
with numeric normalized geometry. Legacy zones are also editable. Changes are
staged into the same Advanced request, with generation-scoped source identities.
Rebase requires unchanged affected collection source; external reorder cannot cause
an old index to edit a different record. The helper's stale-generation precondition
path currently cannot be combined with protected apply.

**Current upstream limitation:** collection requests validate, but master's impact
classifier does not recognize all collection semantics. Pearl therefore blocks their
save as `UnclassifiedCandidate`, retaining the draft. The forms are implemented;
usability of these writes depends on the upstream classification addition. See
[AQUEOUS_MASTER_DEPENDENCIES.md](AQUEOUS_MASTER_DEPENDENCIES.md).

## Collection request examples

Use the generation displayed by `pearlctl aqueous status`. Begin with:

```json
{
  "protocol": 1,
  "expected_generation": "COPY_CURRENT_GENERATION",
  "changes": [],
  "raw_files": {}
}
```

Add the relevant request member. IDs for existing records come from the
selectors and expandable inventories on each page and must stay attached to that generation.

| Editor | Request member and example |
| --- | --- |
| Custom keybindings | `"custom_keybind_changes": [{"op":"add","chord":"Super+E","command":"spawn:nemo"}]` |
| Update/delete custom binding | `{"op":"update","id":"custom:INDEX","chord":"Super+E","command":"spawn:nemo"}` or `{"op":"delete","id":"custom:INDEX"}` |
| Window rule | `"window_rule_changes": [{"op":"add","values":{"app_id":"example","floating":true}}]` (the helper validates supported keys) |
| Update/delete/reorder rule | `{"op":"update","id":"rule:INDEX","values":{...}}`, `{"op":"delete","id":"rule:INDEX"}`, or a separate `{"op":"move","id":"rule:INDEX","direction":1}` operation |
| Snap layouts | `"snap_layouts": [{"id":"halves","zones":[{"id":"left","x":0,"y":0,"width":0.5,"height":1}]}], "default_snap_layout":"halves"` |
| Legacy snap zone | `"snap_zone_changes": [{"id":"ID_FROM_SNAPSHOT","x":0,"y":0,"width":0.5,"height":1}]` |
| Display | `"monitor_changes": [{"id":"live:DP-1","name":"DP-1","x":0,"y":0,"scale":1.25,"transform":"normal"}]` |
| Font/cursor synchronization | `"sync_typography": true` / `"sync_cursor": true` |
| Normalize stacking aliases | `"normalize_stacking": true` |

## CLI and verification

```sh
pearlctl aqueous show
pearlctl aqueous show --text displays
pearlctl aqueous status
pearlctl aqueous status --text layout.gaps_outer
pearlctl aqueous status --text monitors
pearlctl aqueous status --text raw:layout
pearlctl aqueous draft --text '{"protocol":1,"expected_generation":"...","changes":[{"id":"layout.gaps_outer","value":16}]}'
pearlctl aqueous validate
pearlctl aqueous apply
pearlctl aqueous keep       # only during a pending preview
pearlctl aqueous revert
pearlctl aqueous refresh
pearlctl aqueous reload
pearlctl aqueous rebase
pearlctl aqueous discard
```

The CLI retains its 8 KiB frame bound (draft text up to 6,500 bytes). Larger
requests use GTK Advanced, with a 4 MiB UTF-8 bound and depth limit 32. Helper
stdout is capped at 16 MiB and stderr at 64 KiB, drained together. Each helper
invocation has a 35-second deadline and its own process group, killed and reaped
on cancellation. The independent guardian has a separate 150-second overall
parent deadline and 3-second Wayland operation deadlines; the confirmation lease
itself is always 15 seconds. All work runs outside the GTK event thread.

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-aqueous-settings -Doptimize=ReleaseSafe
```

Tests use private buses, temporary HOME/configuration, synthetic keyboard input
and headless outputs. Physical monitor mode/rotation/mirroring behavior remains a
hardware validation task; virtual-output tests do not claim that coverage.


## Matching-master verification

```sh
python3 scripts/build-aqueous-master.py
python3 scripts/aqueous-master-inventory.py
zig build test-aqueous-master -Doptimize=ReleaseSafe
python3 scripts/aqueous-master-upstream-tests.py
```

Tests use private HOME/XDG paths, buses, helper wrappers and virtual displays.
Production master round trips cover structured results, lost stdout, restart-safe
receipt recovery, Keep/Revert, owner crash, invalid candidates and explicit gates.
The separately instrumented upstream suite covers journal crash points, writer
conflicts, replay, native lease races/hotplug/deadlines and rejected tests. Production
and instrumented compositor hashes are recorded separately. Hardware and real
assistive-technology acceptance remain separate from these automated checks.

Private UI validation uses `zig build test-master-ui -Drelease=true -Doptimize=ReleaseSafe`.
It records production themes/accessibility separately from a test-only synchronous
focus query used to verify actual keyboard navigation. Wrapping disclosure buttons avoid a GTK expander Tab trap. Settings actions wrap
at larger text sizes, and a bounded viewport keeps the panel inside its output.
Escape cancels recording and returns focus to the shortcut entry. Advanced also exposes the latest operation receipt and
validated candidate effects. Physical screen-reader acceptance remains separate.
