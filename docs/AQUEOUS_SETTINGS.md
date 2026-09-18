# Aqueous settings in Pearl

Run `pearlctl aqueous show`, `pearlctl aqueous show --section displays`, or
`pearl-settings --page aqueous --section displays` to open Pearl Settings.
The legacy `--text SECTION` spelling still selects the same Aqueous section.
The compact editor remains available at **Control center → Aqueous settings**.
Pearl's new Zig frontend replaces the old external Aqueous settings application;
it does not launch that application. The standalone `aqueous-config` helper remains the canonical
TOML backend; install that helper alongside Pearl. Shell appearance, including
system/installed GTK themes, remains under **Pearl settings**.

The current target is Aqueous master
`88587243059d58d72dd0fe2146d0ebdb64f26474`, helper **0.8.2**, protocol 1.
Pearl discovers the helper through PATH, negotiates capabilities and always uses
`--shell none`. Older helpers can remain readable, but writes require the modern
receipt, candidate-impact and recoverable-commit capabilities.

See [capability coverage](AQUEOUS_CAPABILITY_COVERAGE.md), the
[implementation plan](AQUEOUS_082_UPDATE_PLAN.md), and the concrete
[upstream dependencies](AQUEOUS_MASTER_DEPENDENCIES.md). The original
[additions request](AQUEOUS_T11_ADDITIONS.md) is historical.

The normal window keeps Aqueous edits separate from Pearl preferences. Navigation
and closing retain acknowledged drafts without saving. Apply uses the shell's
existing helper/receipt authority; display Keep/Revert stays available across
page changes. Close, lock or frontend crash requests rollback through the native
lease. Backend loss requires explicit review/rebase or local discard after Retry.

## Navigation

Select **Aqueous** in Pearl Settings to reveal Appearance, Layouts, Input,
Shortcuts, Rules, Displays, and Advanced beneath it. The selected child is
highlighted; the header shows its section title with Aqueous context. Narrow
windows use the same sublist in **Sections**: choosing Aqueous reveals its
children, and choosing a child closes the popover.

Returning through the Aqueous parent restores the last section visited in this
window. Each section retains its scroll position and valid control focus; if
refreshing replaces those controls, focus falls back to the section heading.
Explicit CLI links open at the heading, and an Aqueous launch without a section
opens Appearance. Shortcuts retains the stable CLI section ID `keybinds`.
Navigation transfers pending draft edits without applying or discarding them.

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

The Displays page uses a numbered arrangement diagram and a single selected-screen
editor. Select a diagram screen or its matching button to change resolution,
refresh rate, scale, orientation, or enabled state. Drag screens to reposition
them, use arrow keys (Shift for one-pixel steps), or choose a relative side and
edge alignment. **Exact position** reveals X/Y. **Arrange side by side** stages
a top-aligned layout; **Identify** briefly labels the physical outputs through
Pearl's session service. Disabled connected screens remain selectable.

**Enable HDR** defaults to automatic HDR brightness with inherited/default SDR
brightness. Existing customization is preserved when toggling HDR. **More display
options** contains HDR/SDR brightness controls and **Use automatic settings**, plus
mirroring, output information, profiles, declarations, custom settings, and
preview diagnostics. Automatic SDR brightness removes a local numeric override;
it does not write a string into the numeric field. The separate `auto_hdr`
conversion feature remains an advanced setting and is not enabled by this checkbox.
Unsupported HDR controls explain their availability. Preview capability remains
separate from the ability to retain a configuration draft.

The diagram immediately shows the unsaved arrangement. A revision-matched
canonical validation result supplies authoritative candidate geometry. Edits
merge into the selected output's source-bound declaration; a new exact-connector
override can be added to the active output profile without modifying a shared
wildcard declaration. Ambiguous profiles remain accessible in the advanced
editor. Existing offline declarations and source precedence remain visible there.

The normal Displays footer offers **Discard** and **Apply changes**. Validation
and the native preview are automatic on Apply. A modal **Keep changes** / **Revert**
confirmation uses Aqueous's actual deadline and only enables Keep after
presentation. Escape reverts; reverting retains editable changes. Refresh,
Validate, and Rebase remain under More display options. When a shared draft also
contains edits from other Aqueous sections, Apply and Discard disclose them for
review before proceeding. Pearl's own preferences remain a separate draft.

Position, scale, rotation, mode and mirroring use canonical declaration
mutations when supported; older helpers retain their monitor editor. Scalar display policies use schema controls. Canonical validation determines
whether an edit changes live or deferred output configuration. Both require a native
lease: even `store:true` and an offline-only edit do not authorize unprotected save.

**Apply & save** binds a persistent authenticated native IPC connection to the
candidate generation/digest, compositor session and display revision. Aqueous tests
and applies the candidate and owns its deadline. **Keep displays** sends one
protected helper operation; the helper authorizes, journals, persists and finalizes.
**Revert**, timeout, owner disconnect or invalidation restore the compositor-owned
baseline under its concurrency rules. The former `--display-guard` process and
output-management rollback implementation have been removed.

The declaration editor supports outputs, profiles, profile members and policy in
`wm` or `outputs`. Select a declaration or create one, then choose **Keep current**,
**Set explicit value** or **Use inherited value** for each field. Current local
assignments remain visible. Stage combines edits into the shared draft. Destination
parent and insertion controls support membership and ordering; profile deletion
explicitly deletes or reassigns members. Newly staged profiles can receive members
in the same draft. Aqueous owns source precedence and TOML surgery.

Controls cover enabled/primary, name/EDID matching, position, scale, transform,
mode, mirroring, HDR/auto-HDR, HDR level, SDR white level, auto-HDR boost and adaptive
sync, plus all five policy fields. `identify_by` and `rollback_seconds` retain their
upstream compatibility semantics; the latter does not control the preview timer.
Draft editing is available independently of permission to apply it on hardware.

Production DRM previews remain unavailable. The upstream acceptance build can
exercise explicitly selected SDR outputs; Pearl labels such outputs as acceptance
only. HDR/VRR, DRM mirroring and custom modes remain separately gated. Headless
mirroring requires renderer support. Every display-affecting candidate, including
offline edits, still needs a native lease.

Pearl waits for presentation before showing Keep, and waits for native terminal
status before reporting Revert complete. Session suspension shows a waiting state;
rollback continues on resume. A private durable preview record retains the session,
digest and token across Pearl restarts. Refresh reconciles pending preview/receipt
state; bounded waits leave unresolved outcomes visible and block further saves.
If the begin reply was lost before its token arrived, upstream has no token-free
lookup: uncertainty remains until the compositor session changes. Pearl never
manufactures rollback success. `pearlctl aqueous status --text preview` shows the
last observed native status, including partial rollback and presentation details.

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
Collection-only saves copy descriptors for exactly the affected sources into the
v2 protected contract. The helper may accept a stale global generation only if
those source paths, existence and bytes are unchanged. Apply uses the validation
transaction's effective baseline and full candidate digest. A changed reviewed
digest produces `CandidateReviewChanged`; review the refreshed candidate before
applying again. External reorder or touched-source edits require conflict resolution.
Mixed scalar/raw/display/collection edits retain fresh-generation semantics and
use one atomic candidate; display effects require a native preview.

Rules, custom shortcuts, named layouts/default selection and legacy snap zones
now save through canonical classification and durable receipts. Unknown semantic
extensions still block save and preserve the draft.

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

Pearl selects `aqueous-config` beside the executable of the connected,
same-user compositor, identified through Unix socket peer credentials. It runs
the helper with that compositor's working directory and `HOME`,
`XDG_CONFIG_HOME`, and `AQUEOUS_CONFIG`, `AQUEOUS_LAYOUT`, `AQUEOUS_INPUT`,
`AQUEOUS_OUTPUTS`, `AQUEOUS_RULES`, and `AQUEOUS_APPEARANCE` overrides.
Overrides absent in the compositor are removed from the helper environment.
This keeps co-installed Aqueous packages and custom configuration paths separate
even when Pearl's launch environment or `PATH` belongs to another installation.
Development builds must stage the matching helper beside the compositor.
If that helper or the compositor's process information cannot be read, editing
reports an error instead of falling back to another installation.

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
on cancellation. Native IPC calls have 3-second deadlines. Preview/recovery polling returns
after 35 seconds with a durable unresolved record when necessary; the native
confirmation lease remains 15 seconds. All work runs outside the GTK event thread.

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
zig build test-aqueous-preview test-capture-master test-master-ui -Doptimize=ReleaseSafe
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
