# Aqueous Displays implementation plan

Status: implemented September 16, 2026. The native page, canonical edit adapter,
Identify overlays, and protected confirmation flow are implemented. See the
[implementation evidence](../artifacts/aqueous-displays/README.md) for captures,
verification, and the remaining upstream production HDR preview limitation.
The sequence below records the implementation requirements.

## Approved reference and scope

Implement the Displays page shown in the supplied screenshot, using the
[interactive mockup](mockups/aqueous-displays/index.html) and its
[HDR-enabled capture](mockups/aqueous-displays/hdr-enabled.png) as the visual and
interaction reference. Preserve its hierarchy, wording, spacing, card shapes,
selection treatment, and placement of controls in the native GTK application.
Use the mockup's light and narrow states for corresponding application layouts.

The implementation includes everything inside the Settings window. The study
title, Reset demo, Light preview, sample-device disclaimer, and Demo state
selector outside the window are presentation tools and remain mockup-only.
Names, modes, connection types, display counts, and capabilities come from actual
outputs. Retain the implemented Aqueous navigation sublist.

The primary interaction is: select a screen, change how it looks or where it
sits, select **Apply changes**, and then **Keep changes** or **Revert**.
**Enable HDR** uses automatic settings by default. Complex customization stays
inside collapsed controls.

## Required page composition

| Area | Implementation requirement |
| --- | --- |
| Header | Aqueous context, Displays heading, “Make your screens match your workspace.” subtitle, and connected-display count. |
| Arrangement card | “Arrange your displays”, drag instruction, Identify at upper right, dotted canvas, numbered proportional screens, current/unsaved/preview status, and Arrange side by side at lower right. |
| Display selectors | Numbered buttons immediately below the diagram; one selected display controls both the diagram highlight and editor. Disabled connected screens remain selectable and marked Off. |
| Selected display card | Number badge, monitor name and connection description, enabled switch, Enable HDR checkbox with automatic/custom status, then Resolution / Refresh rate and Scale / Orientation in paired rows. |
| Position card | Side-by-side with the display card at wide sizes; “Place this display”, “Next to”, segmented edge alignment, readable arrangement summary, and collapsed Exact position with X/Y. |
| More display options | Collapsed below the editor cards. Contains mirroring, display information, HDR adjustments and automatic reset, plus access to existing advanced display configuration. |
| Fixed footer | Unsaved-change count and explanation at left; Discard and primary Apply changes at right. Keep visible while the page body scrolls. |
| Confirmation | Modal matching the mockup's Keep/Revert flow, with actual preview status, changed settings, and remaining compositor-owned time. |

Use existing theme tokens and native accessible widgets. Match the reference at
its application-window size; allow native font metrics, display content, larger
text, and window decorations to vary. Wide layouts have two editor columns;
narrow layouts stack them and use the existing Sections navigation popover.
Avoid horizontal page scrolling, clipped fields, or footer-covered controls.

## Current implementation and reuse

- `src/desktop/aqueous_displays.zig` builds a passive placement diagram and
  per-output diagnostic inventories. Replace its primary presentation with the
  approved composition and move those inventories into disclosures.
- `src/desktop/aqueous_display_editor.zig` edits canonical declarations with
  keep/set/inherit intent. Preserve its full functionality under advanced
  controls, sharing mutation handling with the new selected-display editor.
- `src/config/aqueous_display_mutations.zig` stages source-bound operations.
  Extend this path for simple controls; Aqueous continues to resolve declarations
  and edit TOML. Do not introduce an independent config writer.
- `src/desktop/aqueous_settings.zig` owns form lifetime and Aqueous actions;
  `src/settings/window.zig` owns standalone navigation, headings, scroll/focus,
  and the footer host. Integrate page-specific presentation here.
- `src/settings/aqueous_editor.zig` already transports drafts and exposes
  apply, preview choice, remaining time, and recovery state. Reuse that service
  boundary and the existing protected preview lifecycle.
- `src/config/aqueous_display_fields.json` defines `hdr`, `hdr_level`, numeric
  `sdr_white_level`, and the separate `auto_hdr` conversion feature.

## Implementation sequence

### 1. Add a selected-display model and canonical edit adapter

- Build a testable presentation model from `display_observation`, canonical
  declarations, the current draft, and revision-matched candidate results.
  Track runtime output identity separately from configuration declaration IDs.
- Assign stable display numbers for the window's session. Preserve selection
  across form rebuilds, validation, navigation, and resize. On disconnect, cancel
  an active drag and select a remaining output without retargeting old edits.
- Expose actual, draft, and validated values distinctly. The diagram updates
  immediately from draft edits and remains labelled unsaved until accepted;
  only matching canonical results can label it validated or applied.
- Resolve each simple edit to a uniquely identified output declaration using
  canonical identity and precedence data. Preserve unrelated assignments,
  profiles, source order, inherited values, and staged advanced edits.
  Never silently modify a shared profile to change one screen.
- Where a per-output override is needed, stage a narrowly matched declaration
  through the existing mutation API and verify its effect with the canonical
  candidate. Ambiguous matching or an ineffective override must produce an
  actionable message and an advanced-editor route, not a guessed target.
- Combine repeated edits to the same target; returning a value to its baseline
  removes that edit. Count changed settings rather than transport operations.
- Preserve source-token and raw-file conflict checks. Older helpers retain
  their compatible editor path with a clear capability explanation.

### 2. Build the native page to match the screenshot

- Replace the initial diagnostic list with the arrangement card, display
  selector row, and the two editor cards in the required order.
- Populate resolution and refresh choices from advertised mode combinations;
  preserve fractional refresh rates and existing custom values. Mark a mode
  recommended only when the backend provides a preferred-mode indication.
- Bind scale, orientation, and enabled state to canonical values. Preserve
  reflected transforms and nonstandard existing values through advanced options.
  Prevent disabling the last enabled connected display in the simple editor.
- Add the HDR row immediately below the selected-display card header, exactly
  as in the approved screenshot; implement its semantics in step 4.
- Keep Exact position and More display options collapsed initially; retain
  disclosure state during edits and ordinary rebuilds.
- Move declaration/profile/source tools, disconnected declarations, custom modes,
  policy, adaptive sync, auto-HDR, and detailed diagnostics under labelled nested
  disclosures in More display options. Keep their existing editing capabilities.
- Scope new styles in `resources/settings-layout.css` and the existing theme
  stylesheets. Preserve the shared editor's compact host and other Aqueous pages.

### 3. Implement arrangement and positioning

- Draw logical geometry using mode dimensions, scale, and transform. Account
  for negative origins and portrait or reflected screens. Fit all enabled
  displays while retaining usable selection targets and accessible descriptions.
- Clicking a screen or its numbered selector selects the same editor. Dragging
  updates its draft position; snap nearby edges using a threshold measured in
  canvas pixels. Freeze the canvas transform during a drag to avoid jumps.
- Support arrow-key positioning and Shift for fine movement as in the mockup.
  Exact X/Y and relative positioning provide equivalent keyboard controls.
- Populate Next to with other enabled displays. Left/right placement offers
  Top/Center/Bottom alignment; above/below offers Left/Center/Right. Use logical
  dimensions and deterministic integer rounding for positions.
- Recompute a chosen edge alignment after mode, scale, or orientation changes.
  Preserve intentionally custom coordinates rather than forcing an alignment.
- Arrange side by side stages an extended, top-aligned layout for all enabled
  displays in stable order. Support one, two, and more than two outputs.
- Show overlap feedback and block conflicting extended arrangements until
  corrected; mirrored outputs follow their explicit mirror relationship.
  Disable irrelevant position controls for disabled or mirrored outputs.
- Identify must briefly show the same numbers on the physical screens. Add the
  required request through the session service and its output/surface owner;
  keep surface ownership out of the standalone Settings process. Clear overlays
  on timeout, disconnect, lock, or shutdown. The existing `identify_by` policy
  is unrelated. A diagram-only highlight does not complete this requirement.

### 4. Implement HDR with automatic defaults

- Read HDR hardware support separately from `store`, `test`, and `preview`
  permissions. Unsupported displays show a disabled checkbox and a concise
  reason. Unknown support must not be presented as supported.
- Checking Enable HDR for an otherwise automatic configuration stages
  `hdr = true` and `hdr_level = "auto"`; SDR brightness follows the canonical
  inherited/default value. Unchecking stages `hdr = false` and retains tuning.
- Existing intentional brightness customization stays intact when toggling HDR;
  show “Custom settings in More display options.” when it is in effect.
  Do not silently overwrite a user's existing configuration on page load.
- Place HDR brightness and SDR content brightness in the collapsed HDR
  adjustments section, with **Use automatic settings** to restore defaults.
  Disable adjustment controls when the selected display or HDR is off.
- Automatic SDR brightness removes the local numeric override through canonical
  unset/inherit operations; never serialize `"auto"` into `sdr_white_level`.
  If a custom value is inherited, identify it as inherited/custom rather than
  claiming a default was restored. Verify the result with canonical resolution.
- Keep `auto_hdr` and its boost as separate advanced conversion settings.
  Enabling ordinary HDR must not implicitly enable this feature.
- Allow supported draft editing when preview is unavailable, but show the
  backend's reason and prevent Apply from bypassing its capability checks.

### 5. Integrate the simplified footer and confirmation

- On Displays, present Discard and Apply changes as the normal footer actions.
  Put manual Refresh, Validate, and Rebase in advanced/recovery controls;
  contextual errors may expose the relevant recovery action directly.
- Apply flushes pending edits and uses the existing validation and protected
  apply pipeline. Show “Checking settings…” and prevent duplicate submission.
  Freeze the candidate being applied; retain any newer draft separately.
- Surface field and arrangement errors beside the affected control. Preview
  unavailability explains why applying is disabled while retaining edits.
- Show Keep changes only after the compositor reports presentation. Read the
  deadline from the service; do not copy the mockup's simulated 20-second timer.
- Keep sends the existing protected save once. Revert, Escape, dismissal, or
  timeout follows the existing revert lifecycle and waits for terminal status.
  Retain the editable draft after reverting; report saved only after the
  authoritative operation result. Preserve uncertain-result recovery.
- Keep preview choices reachable across navigation and during recovery. Respect
  preview ownership, session suspension, disconnect, and restart behavior.
- The draft is shared across Aqueous sections. Count and disclose all changes
  included in Apply or Discard; if other sections have edits, explicitly identify
  them before the operation. Pearl's separate draft is unaffected.
- Maintain normal footer behavior on other sections and in the compact host.

### 6. Verify behavior and visual fidelity

- Add pure tests for logical geometry, alignment, snapping, negative coordinates,
  rotation/scaling, mode pairing, draft coalescing, mutation targeting, and HDR
  automatic/custom/inherited mappings. Include multiple outputs and ambiguous
  or disconnected identities.
- Extend `tests/integration/test_settings_services.py` with actual UI selection,
  drag and keyboard movement, field changes, disclosures, HDR controls, draft
  retention, shared-draft disclosure, Discard, and Apply/Keep/Revert.
- Extend Aqueous tests for preview denial, validation failure, stale candidate,
  timeout, suspension, hotplug, owner loss, restart recovery, and receipt failures.
  Verify Identify numbers against actual output assignment and overlay cleanup.
- Extend presentation checks with captures matching desktop, HDR automatic,
  HDR custom, unsaved, confirmation, light, narrow, and unavailable mockup states.
  Compare crops of the application content at the same size against the approved
  reference. Review geometry, spacing, colors, typography, and control placement.
- Check native GTK styling, short windows, large text, mixed scaling, keyboard
  focus, accessible names/states, and absence of horizontal overflow. Ensure
  hidden advanced controls are excluded from keyboard traversal.
- Run `zig build test`, `zig build test-settings-app`,
  `zig build test-settings-services`, `zig build test-settings-presentation`,
  `zig build test-settings-integration`, `zig build test-aqueous-settings`, and
  `zig build test-aqueous-preview`. Run the affected surface lifecycle checks
  when Identify adds overlays. Record real hardware checks separately from
  fixture coverage.

## Capability dependency and completion criteria

The current repository documents production DRM previews as unavailable and
HDR preview as separately gated. This UI work cannot assert that a monitor can
apply HDR merely because it can store an HDR declaration. Review the pinned
Aqueous capability reports during implementation. If production HDR remains
blocked, retain the finished automatic-HDR UI and the honest unavailable state,
and record the upstream preview dependency as outstanding for live HDR acceptance.

The work is complete when the native page matches the approved mockup, every
visible action operates through real application state, automatic HDR works on
capable backends, advanced editing remains accessible in collapsed sections,
and the existing preview and persistence guarantees pass regression checks.
Record screenshots and verification results under `artifacts/aqueous-displays/`
and update `docs/AQUEOUS_SETTINGS.md` to describe the delivered behavior and any
remaining backend capability limitations.
