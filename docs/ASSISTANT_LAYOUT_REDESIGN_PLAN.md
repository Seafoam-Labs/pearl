# Assistant layout redesign plan

Status: native GTK layout implemented October 15, 2026. See the
[native captures and validation report](../artifacts/assistant-layout/README.md).
The specification below records the intended design and acceptance scope; the
report distinguishes passing checks from remaining fixture and manual checks.

Bring Settings → Assistant into the visual family of the recently updated
Appearance, Sound, and Power & battery pages. Keep the most common decisions
visible: **enable the assistant → choose a model → choose CPU or GPU**. Group
setup, search engines, comparisons, and resource limits behind useful summaries.
Keep every existing configuration option and operation available.

Review the [desktop](mockups/assistant-layout/desktop.png),
[light](mockups/assistant-layout/light.png),
[390 px layout](mockups/assistant-layout/narrow.png),
[expanded settings](mockups/assistant-layout/details.png),
[model comparison](mockups/assistant-layout/comparison.png), and
[operation states](mockups/assistant-layout/states.png).
The [asset guide](mockups/assistant-layout/README.md) contains editable sources
and reproduction instructions.

## Reference and scope

The reference is the implemented settings UI, including the
[Appearance captures](../artifacts/appearance-redesign/README.md),
[`preferences_view.zig`](../src/settings/preferences_view.zig),
[`sound_view.zig`](../src/settings/sound_view.zig),
[`power_view.zig`](../src/settings/power_view.zig), and shared
[`settings-layout.css`](../resources/settings-layout.css).
Reuse their rounded cards, clear headings, native selection controls, wrapping
rows, and expandable secondary sections. Retain the window navigation, header,
body scroll area, and shared preference footer.

The current [`assistant_view.zig`](../src/settings/assistant_view.zig) presents
General, Models, Runtime & acceleration, Search engines, and Resources as a long
form. Repeated explanatory paragraphs and vertically stacked action buttons make
model choice and readiness difficult to scan. The embedded
[`benchmark_view.zig`](../src/settings/benchmark_view.zig) adds another dense form
and result list beneath Models.

This proposal covers those two settings views and their existing dialogs.
Launcher results and the floating conversation remain outside this change.
No preference schema, model catalog, runtime policy, search defaults, or benchmark
scoring changes are needed. Production implementation and any generation helpers
remain Zig; CSS and SVG serve their existing styling and asset roles.

## Page structure and complete control inventory

| Area | Proposed layout | Controls and behavior retained |
| --- | --- | --- |
| Launcher assistant | Compact card with enable switch, draft state, and short privacy explanation | Enable launcher assistant; off by default; local answers; only submitted questions or explicit connection tests send searches; experimental status |
| Model | Full-width selected-model dropdown, installation status, Verify action, and Model options | All five managed models plus custom GGUF; exact size and quantization; custom absolute path and compatibility checks; selected license link; explicit download and remove actions |
| Runtime & acceleration | Visible CPU / Automatic / Selected GPU radio tiles with runtime summary; expandable Runtime setup & checks | System installation, Pearl runtime package, custom executable path and Browse; Set up runtime; Discover devices; Check runtime and model; backend and device selection; CPU fallback; advanced layer and memory settings |
| Search engines | Collapsed summary naming the default and number enabled; engine selector and contextual editor inside | Add/remove engine; display name; all five connection kinds; endpoint or engine ID where required; language; enabled/default state; Safe search; search all enabled engines, maximum 3; password entry; session-only Secret Service choice; immediate save/remove key and connection test |
| Compare models | One expandable section directly below Search engines, with a shortcut from Model options | Every candidate and license; installed status and pending download size; all hardware/depth modes; start, stop-answer-and-start, cancel, skip, refresh; saved history, sorting, samples, adoption, export and deletion |
| Resources & behavior | Collapsed summary of automatic/custom values and idle timeout; full rows inside | CPU threads, context tokens, generation tokens, idle unload seconds, Read search result pages, and session/conversation behavior explanation |

The three primary cards start expanded. The four disclosures (runtime setup,
search engines, comparisons, resources) start collapsed and remember their state
while the window is open. Do not duplicate the comparison view under both Model
and Runtime. Existing comparison entry points expand and focus the same section.
Validation errors reveal the relevant section. A collapsed header still reports
busy, failed, or incomplete operations, with a route to their details.

## Layout and visual rules

- Use 16 px card corners, approximately 20 px internal insets, 16 px card gaps,
  and the existing 30 px desktop / 16 px narrow body margins. Reuse native row
  spacing and approximately 44 px minimum interactive targets.
- Reuse theme tokens and GTK native colors. The mockups illustrate the lavender
  Material palette; do not hardcode these SVG colors into application widgets.
- Give every section one title and one concise summary. Put long explanations
  beside the affected controls or inside their details, keeping immediate-action
  consequences visible before the action.
- Use the existing grouped check-button/radio treatment for CPU modes, including
  a visible selected indicator and accessible checked state. CPU remains the
  default. Automatic is a selection policy, not proof that a GPU is in use.
- Keep one full-width model selector rather than a tile for every model. Show
  full names, quantization, size, and installation state without inventing
  performance rankings. Model options contains the license, download/removal,
  custom-file controls when selected, and the comparison shortcut.
- Keep Apply & save as the shared draft action. Neutral local actions use clear
  verbs such as Verify model now or Test connection now. Remove/delete actions
  belong in clearly named secondary controls with existing safeguards.
- At 390 px, use the window's Sections menu, stack CPU modes and long action
  groups, and place fields below labels when necessary. All content scrolls above
  the existing footer. Resources follows Compare models below the narrow crop.
  Never shrink labels to force them into a fixed row.
- At narrow widths, comparison results become vertically stacked result cards
  with labeled metrics and actions. Wide layouts align metrics in columns. Long
  model names, paths, errors, and translated labels wrap naturally.

## State and interaction rules

### Drafts and readiness

Enablement, model/runtime/compute choices, engine configuration, and resource
values continue editing the shared preferences draft. Apply persists it and
Discard restores committed values across tabs. Preserve the current Apply
confirmation when an active answer must stop; Keep editing leaves it running.
Applying Off stops assistant processes and clears session conversations.

Show On in draft or Off in draft when enablement differs from committed settings.
Do not label a downloaded model as verified or ready. Keep distinct model-file,
runtime-check, provider, and active-operation statuses. Checks belong to the
configuration tested; after a relevant draft change, show Not checked for this
draft instead of carrying forward a misleading success badge. Preserve actual
diagnostic details in a selectable, expandable area.

Selecting another model retains the current reset to its automatic context and
generation profile. Present a short explanation beside that selection. Custom
GGUF uses its editable absolute path and local verification flow, without an
invented Pearl file-size cap. Removing a managed model retains the existing
disable-and-Apply requirement.

### Immediate actions and feedback

Opening the page, choosing a model, or expanding a section must not download,
install packages, run inference, test a provider, or send a search. Comparison
expansion may read the existing local hardware/availability and saved history,
as it does today; that is separate from starting a benchmark.

Downloads/removals, package setup, verification, runtime/device checks, benchmark
runs/history operations, and Secret Service key changes retain their existing
explicit-operation semantics. Downloads and package installation are not undone
by Discard. Saving a key remains separate from saving preferences. Connection
tests disclose the sample query and selected destination before they run.

Put progress, details, and cancellation near the initiating card. Retain a
page-level operation summary when its section is collapsed or offscreen. Cancel
stays available until worker cleanup finishes, except where the existing action
does not support cancellation. Runtime package setup opens the existing terminal
authentication/confirmation flow; closing Settings does not cancel that package
transaction. Do not present a false Cancel package installation control.

Keep current worker ownership, exclusivity, shutdown, and busy guards. Section
collapse must not destroy workers or discard their state. The layout refactor
must not enable competing model, runtime, and benchmark actions.

### Conditional details

Custom runtime selection reveals path and Browse. GPU controls are relevant to
Automatic and Selected GPU; retain existing backend/device preferences and
semantics. Explicit CPU fallback is editable for Selected GPU, while Automatic
already includes fallback. Preserve advanced offload layers and memory target,
including zero-as-automatic, shared system RAM explanation, and the fact that
memory targets are estimates rather than hard caps.

Search engine fields depend on the connection kind. Bing shows no API-key or
endpoint form. SearXNG connections show the existing endpoint; API-backed engines
show key controls and the engine ID where required. Keep the existing provider
availability guidance with its associated option. Do not clear unrelated saved
fields just because the editor hides them. A failed test identifies its engine;
keys never appear in summaries, diagnostics, screenshots, or preferences.

Resources keeps exact numeric fields and all existing ranges, with Automatic or
Model profile as the readable meaning of zero. Generation budgets include
reasoning where applicable. Preserve the absence of an artificial host RAM cap.

### Model comparisons

Keep model download size separate from measured runtime RAM. Show actual backend,
completion time with range, outcome, and sample availability. CPU fallback cannot
appear as a successful GPU run. Unavailable metrics stay unavailable. Existing
stale-result and workload-compatibility checks still determine adoption and
suggestions; a layout change must not rerank unlike context workloads.

Retain all measured details in Show samples, including configuration, timing,
throughput, memory limitations, and sample answers. Use this configuration edits
the draft and requires Apply. Keep export, delete, interrupted-history handling,
cancel, and skip reachable without relying on a hover-only menu. Never describe
the illustrative mockup results as measured performance.

## Implementation sequence

1. **Restructure the Assistant view.** In `assistant_view.zig`, introduce scoped
   card, summary, wrapping-action, and disclosure helpers using existing GTK
   patterns. Keep current widget fields and callbacks so the window diagnostics
   and integration controls remain connected. Build the enable and model cards
   first; preserve `save`, `update`, and the shared Editor contract.
2. **Group runtime and engine details.** Add native grouped compute selectors
   mapped to existing enums. Reorganize setup, conditional provider fields, and
   resources; add draft-derived summaries and operation feedback. Guard programmatic
   refreshes with the existing filling/editing flags, preserve focus and partially
   entered text, and avoid rebuilding the page on its polling timer.
3. **Integrate comparisons.** Move the existing comparison expander to its own
   page section and route shortcuts to it. Update `benchmark_view.zig` to use
   compact candidate rows, a wrapping toolbar, and responsive results while
   retaining its worker lifecycle, measured data, and adoption rules.
4. **Style and inspect.** Add only scoped `.assistant-view` and comparison styles
   to `resources/settings-layout.css`, including light and GTK variants. Change
   `window.zig` only as needed for existing diagnostics or focus/reveal behavior.
   Retain the shared navigation, breakpoints, scroll ownership, and footer.
5. **Validate native behavior.** Extend the existing Assistant integration suites
   for disclosure/focus behavior, conditional fields, progress visibility, narrow
   layout, and preserved draft semantics. Capture native screenshots alongside
   the mockups and report actual results before considering implementation done.

## Acceptance and verification

| Check | Acceptance criterion |
| --- | --- |
| Visual family | Shared headers/footer, card rhythm, theme colors and radio selection match Appearance, Sound and Power |
| Control parity | Every control/action in the inventory remains keyboard reachable, including custom paths, key management, skip, history and model removal |
| Draft behavior | Model/runtime/provider/resource edits persist only on Apply; Discard restores prior values; model-profile reset and active-answer confirmation remain correct |
| Explicit operations | Opening/navigating/expanding does not start external work; tests and downloads only run from their actions; immediate side effects are not described as discardable |
| Readiness and recovery | Missing model, unchecked runtime, failed check, locked Secret Service, provider failure, download progress, cancellation and active answer have visible next steps |
| Responsive layout | 1200, 1040, 560, 440 and 390 px widths; 14 and 24 px text; dark, light, GTK; scales 1, 1.25, 1.5 and 2; no horizontal overflow or footer overlap |
| Accessibility | Native accessible names/states; logical Tab order and radio keyboard handling; visible focus; readable summaries; failures conveyed by text; focused controls scroll into view |
| Comparison fidelity | No fabricated metric or readiness; actual backend and stale status retained; samples accessible; draft adoption and immediate history actions remain distinct |
| Lifecycle | Navigation, collapse, cancellation, and closing Settings preserve current job cleanup and runtime exclusivity |

For implementation, run Zig formatting and the appropriate build/unit checks,
then `zig build test-agent-model-settings`, `zig build test-agent-benchmark-settings`,
and `zig build test-agent-launcher`. Run the settings presentation, navigation,
and accessibility suites for the changed layout. Use the existing isolated
fixtures for operations rather than initiating real package installs, model
downloads, or paid-provider calls as visual tests. Record failures and remaining
manual screen-reader/scale checks explicitly.

The original design assets were validated by compiling/running the Zig generator,
parsing/rendering all SVGs, inspecting the PNGs, and checking links and whitespace.
The implementation adds `zig build test-assistant-layout` for the native layout
and interaction matrix. See the linked native report for actual test outcomes.
