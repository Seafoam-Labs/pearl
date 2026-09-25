# Shared rule builder for Aqueous window rules

Status: native editor implemented; authoritative tester remains a separate
backend milestone. The original interactive mockup is retained as design evidence.

Implemented: shared presentation scaffolding, schema-backed condition/effect
rows, ordered cards with pagination, lossless draft projection and merged deltas,
revision/digest conflict retention, pending addition editing/deletion, isolated
moves, normal validation/Apply/receipts, and unavailable tester disclosure.
The current helper treats new empty strings as removals except for Launch tag;
unsupported new empties are rejected and existing empties are preserved.

Deferred as allowed by step 5: authoritative sample evaluation, the shared
compositor policy module, helper capability, and `aqueous.rules.test` transport.
No matching behavior is simulated in the native frontend. See
[implementation evidence](../artifacts/window-rules/README.md) for executed checks.

Reuse the notification filter editor's creation flow in **Pearl Settings →
Aqueous → Rules**: readable rule cards, Add rule, a focused editor with condition
rows, inline validation, reversible deletion, and a sample tester. Add an
**Apply these settings** section with typed effect rows. Keep the existing
Aqueous draft, validation, save/reload, receipts, and protected-apply workflow.

[Interactive mockup](mockups/window-rules/index.html) ·
[Captures and prototype checks](mockups/window-rules/README.md)

## What is shared

Extract a small native presentation component from
`src/settings/notification_filters_view.zig` into a proposed
`src/settings/rule_builder.zig`. Share card framing, add/remove rows, modal
layout, scrolling, inline errors, accessible labels, conflict retention and
focus restoration. Pass field descriptors, value-widget factories, summaries,
validation, commit/delete callbacks, and domain-specific help into the component.
Keep the two domain adapters responsible for data and policy. Avoid a new generic
rule language or a common persisted rule schema.

| Behavior | Notification filters | Window rules |
| --- | --- | --- |
| Data owner | Pearl preferences | Aqueous helper/compositor |
| Draft adapter | `settings/editor.zig` | `settings/aqueous_editor.zig` |
| Conditions | All / Any | All present matchers, always |
| Text matching | Literal equals/contains, optional Unicode case folding | Anchored, case-sensitive byte globs |
| Multiple matches | Block takes priority | First matching rule wins; effects do not merge |
| Result | Block / History only | Typed window settings |
| Ordering | No precedence | Source order is meaningful |
| Name and enabled switches | Persisted fields | Not supported by current schema; omit |
| Final save | Apply & save Pearl preferences | Existing Aqueous validation and apply route |

Window card titles are derived from their matchers, not persisted user labels.
Do not implement disable by deleting rules or adding impossible matchers. A
future name/enabled feature needs an explicit Aqueous schema/runtime extension.

## Evidence and existing contracts

The current rule form lives in `src/desktop/aqueous_collections.zig`. It already
reads `collection_schema.window_rules.fields`, stages add/update/delete/move,
preserves explicit false and zero through inheritance controls, and shares the
Aqueous draft. `src/desktop/aqueous_settings.zig` renders it alongside scalar
Rules settings and the expandable inventory. Replace only the window-rule form;
retain Game mode settings, other collection editors and Advanced access.

`src/config/aqueous_collections.zig` supplies `stage`, `editPending` and `scalar`.
Existing rule identities are scoped to the helper generation. Pending additions
have draft-local indices, not backend identities. `stage` currently refuses
mixing a move with other operations. Structured edits and `raw_files.rules`
are mutually exclusive.

The local Aqueous source confirms the contract:

- `settingsApplication/src/backend/operations.zig::writeCollectionSchema`
  advertises all-present, first-match-wins and case-sensitive anchored globs.
- `settingsApplication/src/backend/collection_schema.zig` defines field keys,
  types, options, numeric bounds and rule validation.
- `compositor/aqueous/wm/rules/engine.zig::resolve` is the matching authority.
- `compositor/aqueous/wm/rules/glob.zig` defines byte-wise `*` / `?` matching.

These paths are relative to the sibling Aqueous checkout. Inspect the helper
paired with the running compositor at implementation time; do not infer runtime
support from this checkout or older inventory prose. Pearl's current
`src/config/aqueous_contract.zig` separately gates collection editing and
protected collection apply. Some older documentation describes all collection
saves as unsupported; current capability and impact responses are authoritative.

## Proposed page and editor

The Rules section starts with a **Window rules** heading, rule count and Add rule.
A short note says “Rules run from top to bottom. The first match applies.” Each
card shows its position, generated matcher title, condition summary, explicit
effect chips, Edit, and named Move earlier/later buttons. An empty state explains
that new windows use normal Aqueous behavior until a rule matches.

The modal has two groups:

1. **When a window matches**: field, comparison/pattern, value, Remove;
   Add condition offers only unused matchers. Show “All conditions must match”.
2. **Apply these settings**: effect selector, typed value, Remove; Add setting
   offers only unused effect fields. Keep additional effects under Advanced
   settings if needed, without hiding configured values from the summary.

Save rule stages an Aqueous draft. Cancel discards only modal edits. Delete rule
stages deletion and can be undone with Discard. The footer says that Apply saves
all pending Aqueous changes; it does not save the separate Pearl preference
draft. Use existing Aqueous Validate / Apply / Discard controls and outcomes.
Show saved-but-reload-failed separately from fully applied. If impact requires
protected confirmation, continue through the existing protected workflow.

For v1, moving a saved rule is an isolated transaction: enable move only when
there are no pending Aqueous mutations. After staging one move, disable further
moves and other rule edits until Apply or Discard; explain why inline. Other
Aqueous pages must also respect the existing mutation guard. Preserve the
underlying helper contract instead of promising arbitrary drag reorder. Future
batched reorder needs generation-aware projection and an extended mutation
contract, including mixed add/delete/move cases.

## Conditions, effects and preservation

| Input | Initial UI and semantics |
| --- | --- |
| Application ID, X11 class, Title | “Matches pattern”; `*` = zero or more bytes, `?` = one byte. No Any switch or Match case checkbox. Backslash is not a general glob escape for these fields. |
| Launch tag | Tag pattern, using Aqueous's separate backslash-escape behavior; missing tag never matches. |
| Content type | Typed exact enum from supported schema. Explain that content-type rules only apply the visual/client-buffer effects allowed by the runtime; placement is ignored. |
| Window type | Exact X11 type enum; expose applicable scope/type controls together. Do not treat a multi-type X11 window as a single unchecked text field. |
| Scope | Explicit managed/unmanaged selector where supported; default managed. Scope alone is not a matcher. |
| Boolean effect | Inherit / On / Off; false remains an explicit setting. |
| Numeric effect | Inherit or numeric value with schema bounds and units; zero remains explicit wherever permitted. |
| Enum/text effect | Inherit or schema-validated value; output is a connector name, workspace a 1-based index. |

Common effects: Floating, Workspace, Output, Fullscreen, Stack layer, Placement,
Width/Height, Opacity and Blur. Additional supported keys—including position,
size/anchor/scale, focus, fixed position, taskbar/switcher visibility, scrolling
width and HDR/buffer options—must remain editable or visibly preserved.
Content-type and unmanaged-scope effect restrictions come from helper/runtime
validation; do not imply that ignored settings will apply.

No later rule supplies missing effects to the first match. “Inherit” means
remove this explicit field and use Aqueous's normal rule/default behavior.
Removing an existing effect emits `null` in the update; omitting a field means
leave it untouched. Preserve original values, explicit empty strings and
unsupported/unknown fields. Default new text conditions to nonempty input;
provide an explicit advanced empty-pattern choice for supported legacy cases,
rather than silently trimming or deleting an existing empty matcher.

Require at least one actual matcher for a new rule and a useful explicit effect
in the guided creation form. Existing rules without explicit effects may be
intentional first-match barriers: retain them and explain their behavior rather
than refusing to open or silently removing them. Never migrate existing rules
by reconstructing only the visible widgets. Duplicate field rows are invalid.

The schema currently marks app ID/class/title with `matcher` metadata but tag,
content type and window type are also matchers in the engine. Resolve that gap
with versioned semantic descriptors from Aqueous, or a tested compatibility map
for known versions. Unknown keys must not be guessed as effects or discarded.
Do not hardcode notification limits (32 rules / 8 conditions) onto Aqueous;
retain its document/operation limits and bound/paginate the rendered list.

## Draft projection and safe editing

Add a proposed `src/config/aqueous_rule_editor.zig` projection layer that produces
ordered cards from the base snapshot plus staged changes. Merge update values
by key, apply null removals, hide deleted rules, and include unsaved additions.
Do not identify rules by matcher text: duplicate rules are distinct source
records. Track the captured backend generation, shared draft revision and local
addition token/index with every modal. Never reuse a stale index after another
writer inserts or deletes an addition.

On Save, compare those versions, overlay only edited keys, and preserve unrelated
Aqueous mutations. Repeated edits of the same rule must merge earlier pending
field deltas; the current `stage` replaces a same-ID patch wholesale, so passing
only the newest field delta would lose earlier changes. Add tests before changing
that behavior. A competing change keeps modal input and offers review/reopen;
never silently overwrite it. External reload invalidates generation-scoped IDs.
Raw-file conflicts remain visible and require resolving the existing draft.

The extracted builder owns modal input outside page rebuild arenas. Audit
`View.build`, `keepDraft`, `syncRequest`, refresh, disconnect, lock and teardown:
no callbacks may reference widgets or schema values freed by a snapshot refresh.
Hide locked/suspended dialogs without losing input and require normal activation
after unlock. Restore focus to the edited card, or Add rule after deletion.

## Test window: a separately gated backend addition

Provide a read-only **Test window** expander following the notification tester.
Accept a manual sample of app ID, X11 class, title, optional tag, scope, content
type and advertised X11 types. A missing tag differs from an explicitly empty
tag. A window picker can follow later, using existing observed identity fields
and disclosing that it copies sample metadata only.

A production tester requires a new advertised Aqueous capability and read-only
helper operation; no such operation is assumed available today. It should use
the compositor's parser and resolver, through a shared Aqueous policy module,
on the fully projected draft. Do not reuse Pearl's notification matcher or
create an independent “equivalent” Unicode/glob engine in Pearl. The existing
recursive non-tag glob implementation also warrants bounded-input/work-budget
review before exposing arbitrary test samples; any optimized matcher must pass
differential tests against the compositor semantics.

Proposed Pearl request `aqueous.rules.test`: backend epoch/view, Aqueous base
version, draft revision, sample serial and bounded typed identity. The backend
reads the retained draft, checks lock/availability/current versions, and invokes
the matching helper read-only. Proposed result: first matching source/draft
identity, effective supported settings, later matches marked “Not applied”,
ignored-effect explanations, versions and serial. Missing authoritative support
shows “Testing requires a newer Aqueous helper”; normal rule editing continues.
The browser prototype demonstrates this future-capability state.

Reject stale/busy/invalid samples, clear results after draft/sample changes and
ignore replies with outdated revisions, generation, epoch or serial. Proposed
new tester bounds: 4 KiB per identity string, existing framed transport limit,
bounded match explanations with pagination/truncation, and a cancellable timeout.
No window movement, focus change, file write, reload, or content/pattern logging.
Testing matching must not be described as validating every live placement effect.

## Implementation sequence

1. **Characterize and project.** Add pure round-trip and projection tests for
   current schema, identities, inheritance, pending additions and isolated moves.
   Resolve matcher metadata and preservation gaps before replacing the form.
2. **Extract the native builder.** Move presentation scaffolding out of the
   notification view behind callbacks. Retain its schema, tester and behavior.
   Run notification acceptance to protect the just-completed feature.
3. **Add the window-rule adapter.** Proposed
   `src/settings/window_rules_view.zig` uses the shared builder and Aqueous editor;
   integrate at `desktop/aqueous_settings.zig` / `desktop/aqueous_collections.zig`.
   Keep the legacy path for unsupported helper contracts and retain Advanced.
4. **Integrate save/ordering and recovery.** Use the current shared draft,
   receipts, classified impact, protected apply and reload state. Fix relevant
   failures in the broad Settings service acceptance before claiming release
   readiness; its Aqueous Apply timeout is recorded in the notification evidence.
5. **Add the authoritative tester across repos.** Implement helper capability,
   shared evaluator, bounded protocol and Pearl client/backend dispatch. Land
   this independently of the editor if the installed helper cannot yet support it.
6. **Verify and document.** Update `AQUEOUS_SETTINGS.md`, field inventory,
   frontend API, ownership docs and development test instructions; replace stale
   collection-support descriptions with capability-qualified explanations.

## Acceptance and test matrix

| Area | Required checks |
| --- | --- |
| Shared UI | Notification filters retain all existing behavior; separate draft ownership; stable focus, accessible field/remove names, Escape/Cancel, visible inline errors. |
| Projection | Duplicate identities, add/edit/delete before Apply, multiple updates to one rule, null vs omitted vs false/zero/empty, unknown keys, move-only flow and raw-file conflicts. |
| Matching | AND, anchored case-sensitive byte globs, multibyte `?`, absent/empty identities, tag escapes, scope/X11 types, content-type restrictions, first winner and later matches. |
| Transactions | Shared draft survives navigation/reopen, Apply/Discard, external reload, stale generation/revision, protected apply, read-only sources, saved/reload-failed distinction, no uncertain mutation replay. |
| Tester | Capability absent, sample bounds/work timeout, stale results, lock/disconnect, no files/windows/reload side effects, effective results agree with Aqueous runtime. |
| Presentation | Dark/light/GTK, 390/560/wide layouts, direct wide-to-narrow resize, large text, short dialog with reachable footer, keyboard and AT-SPI inspection. |

Run `zig build test`, existing `test-notification-filter-settings`,
`test-aqueous-settings`, `test-settings-services` and relevant presentation suites.
Add `test-window-rule-settings` using private Aqueous/D-Bus sessions. In Aqueous,
run glob/resolver tests and backend collection-impact/protected-collection suites.

Acceptance example: create app ID `firefox` + title `*Picture-in-Picture*`, set
Floating = On and Stack layer = Above, stage, validate and apply. A matching
window gets the first rule's supported effects; a later general Firefox rule is
reported as not applied. Edit and Discard restore the saved rule. No Pearl
notification rules or preference draft are modified by this workflow.
