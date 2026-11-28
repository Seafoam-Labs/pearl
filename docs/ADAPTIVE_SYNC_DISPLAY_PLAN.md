# Plan: Expose Adaptive Sync (VRR) in Pearl Settings → Displays

Tracks [Seafoam-Labs/Aqueous#159](https://github.com/Seafoam-Labs/Aqueous/issues/159) ("(FR) VRR support").

> **Status: implemented.** UI, gating, draft-block arm, i18n templates, docs and
> integration tests are in place. `test-settings-displays` passes (18 checks,
> including `adaptive-sync-exposed-and-gated-on-unsupported-output` and
> `staged-adaptive-sync-surfaces-and-blocks-unsupported-preview`); `test-i18n`,
> `check-templates` and catalog `check` pass; `build-settings` and `build-shell`
> compile. Remaining acceptance: manual verification on VRR-capable DRM hardware
> (steps below), which the headless fixture cannot exercise.

## Background

Issue #159 reported that VRR could not be found in Pearl Settings' display options.
The maintainer confirmed VRR already works end-to-end; the workaround is editing
`~/.config/aqueous/outputs.toml` (`adaptive_sync = false` → `true`). The issue stays
open to expose the setting properly in the Displays panel.

**The entire backend chain already exists — this is a Pearl UI task.** No compositor
or `aqueous-config` helper changes are required for basic exposure.

### What already exists

| Layer | Location | State |
| --- | --- | --- |
| TOML schema | `Aqueous/outputs.toml` template; `compositor/aqueous/wm/output/config.zig` (`Spec.adaptive_sync`, `Spec.fullscreen_only_adaptive_sync`, parsed ~283, known keys ~641) | ✅ both keys |
| Compositor policy | `compositor/aqueous/adaptive_sync_policy.zig`; `Output.zig` `actualAdaptiveSync()` (~3000), `prepareAdaptiveSync()` (~3039), `commitAdaptiveSync()` (~3054); `OutputManager.zig` `applySpecs()` (~239), atomic commit (~919) | ✅ incl. unsupported/commit-failed handling, mirror exclusion, fullscreen-only gating |
| Helper mutations | `Aqueous/settingsApplication/src/backend/display_mutations.zig` (`boolean()` ~355 includes both VRR keys); round-trip tests in `tests/backend/test-display-mutations.py` | ✅ |
| IPC observation | `compositor/aqueous/DisplayModel.zig`: per-output `support.vrr` (`{store, test, preview, reason}`, ~98), `actual.adaptive_sync` (~76), `actual_vrr`, `effective_adaptive_sync`, `adaptive_sync_error` (~79–81); configured state includes both keys (~148) | ✅ |
| Pearl advanced editor | `pearl/src/config/aqueous_display_fields.json` already declares `adaptive_sync` and `fullscreen_only_adaptive_sync` (boolean); rendered by `src/desktop/aqueous_display_editor.zig` under "Display declarations…" | ✅ (but buried — the discoverability problem in #159) |
| Pearl simple Displays panel | `pearl/src/desktop/aqueous_display_setup.zig` — `Control` enum (line 14) has **no** adaptive-sync entry | ❌ the gap |

Pearl's model layer is key-generic: `src/config/aqueous_display_setup.zig`
`value(base, draft, output, key)` merges configured → actual → staged draft, and
`stage()` (~150) builds `display_declaration_changes` ops for any known key. Staging
`adaptive_sync` therefore needs no model-layer changes.

## Goal

A discoverable **Adaptive sync (VRR)** toggle in the selected-display editor, with a
**fullscreen-only** sub-option, capability-aware sensitivity/help text, and correct
draft/preview gating — matching the existing HDR control pattern.

### Non-goals

- No compositor, helper, or TOML-schema changes.
- No change to VRR policy semantics (mirroring exclusion, fullscreen-only gating stay as-is).
- The declaration editor keeps working unchanged as the advanced escape hatch.

## Design decisions

1. **Placement: main settings card, directly under the HDR row** (not inside
   "More display options"). Rationale: #159 is a discoverability bug — the reporter
   opened "More display options" and found only the declaration dump. HDR is the
   closest analogue (boolean, capability-gated, per-output) and lives in the main
   card at `render()` ~413–420. `AQUEOUS_DISPLAYS_IMPLEMENTATION_PLAN.md:109`
   anticipated adaptive sync under "More display options"; this plan deliberately
   promotes the master toggle for discoverability while the fullscreen-only
   sub-option sits indented beneath it (same visual pattern as `hdr_help`).
2. **Widgets:** `gtk.CheckButton` "Adaptive sync (VRR)" + secondary help label
   (`vrr_help`), and an indented `gtk.CheckButton` "Only when a fullscreen app is
   running" for `fullscreen_only_adaptive_sync`. CheckButton matches HDR and is
   already handled by `bind()`'s `toggled` path — no signal plumbing changes.
3. **State source:** `f.val("adaptive_sync")` / `f.val("fullscreen_only_adaptive_sync")`
   (configured → actual → draft merge), exactly like `hdr`.
4. **Capability/sensitivity:** mirror the HDR logic at `refreshControls()` ~155–171:
   - `vrr_supported = support.vrr.test or support.vrr.preview or actual.adaptive_sync`
     (note: prefer `support.vrr` + `adaptive_sync_status`/`vrr_capable` over
     `actual_vrr` alone — `actual_vrr` is the *effective* state and is legitimately
     false while fullscreen-only is idle).
   - Switch sensitive iff `head.enabled and vrr_supported and !mirrored`
     (policy forces VRR off while mirroring — `adaptive_sync_policy.target()`).
   - Fullscreen-only checkbox sensitive iff the above **and** the master toggle is on.
5. **Help text (`vrr_help`):**
   - display off → "Turn on this display to use adaptive sync."
   - unsupported (`support.vrr.reason == "vrr_unsupported"`) → "This display does not support adaptive sync."
   - preview unavailable → "Adaptive sync preview is not available for this display."
   - mirrored → "Adaptive sync is unavailable while mirroring."
   - `adaptive_sync_error` set (`unsupported` / `commit_failed`) → surface it, e.g. "Adaptive sync could not be enabled on this display."
   - on + effective → "Active." / on + fullscreen-only idle → "Enabled for fullscreen apps."
6. **Draft gating:** extend the `unavailable` loop in `refreshControls()` (~236–242)
   with a VRR arm mirroring the HDR arm: if the merged `adaptive_sync` value is true
   and `support.vrr.preview != true`, block apply with "Adaptive sync preview is
   unavailable on this backend." This keeps the simple panel consistent with HDR;
   store-only edits remain possible via the declaration editor.

## Implementation steps

All edits in `pearl/src/desktop/aqueous_display_setup.zig` unless noted.

1. **`Control` enum (line 14):** add `adaptive_sync`, `fullscreen_only_adaptive_sync`.
2. **`Form` struct:** add `adaptive_sync: *gtk.CheckButton`,
   `fullscreen_only: *gtk.CheckButton`, `vrr_help: *gtk.Label`.
3. **`render()` (~420, after the HDR row):** build a `vrr_row` column mirroring
   `hdr_row`: CheckButton + `vrr_help` (margin-start 24), then the indented
   fullscreen-only CheckButton. Wrap strings in `@import("i18n").dtr("pearl", …)`
   and set accessible names via `w.name(…)`.
4. **Form init (~493) + inline bind list (~494):** add the three fields and
   `.{ adaptive_sync, .adaptive_sync }, .{ fullscreen_only, .fullscreen_only_adaptive_sync }`
   entries. `bind()` auto-registers accessibility IDs `display.adaptive_sync` and
   `display.fullscreen_only_adaptive_sync` (used by integration tests).
5. **`change()` (~611):** add arms:
   ```zig
   .adaptive_sync => try f.stage("adaptive_sync", .{ .bool = f.adaptive_sync.getActive() != 0 }),
   .fullscreen_only_adaptive_sync => try f.stage("fullscreen_only_adaptive_sync", .{ .bool = f.fullscreen_only.getActive() != 0 }),
   ```
   No companion staging needed (unlike HDR's `hdr_level = "auto"`); compositor
   defaults apply when the key is unset. Verify the compositor default for
   `fullscreen_only_adaptive_sync` before choosing the checkbox's fallback display
   state (use `f.val(...)`, which already resolves configured/actual).
6. **`refreshControls()` (~155–171):** set active states, sensitivity, and `vrr_help`
   per Design decisions 4–5. Read `mirrored` (already computed ~180 — move the VRR
   block after it or recompute `m.str(f.val("mirror_of")).len > 0`).
7. **Draft-block loop (~236–242):** add the VRR arm from Design decision 6.
8. **i18n:** add the new strings to the Pearl translation catalogs following the
   existing "Enable HDR" entries (see `src/i18n/` and the language-pack tooling,
   `tests/test_language_packs.py`).
9. **Docs:** update `pearl/docs/AQUEOUS_SETTINGS.md` (Displays section, ~201) to
   document the new toggle and its relationship to the declaration editor; note
   the `outputs.toml` keys for advanced users.

## Tests

- **Integration (primary):** extend `pearl/tests/integration/test_settings_displays.py`
  (drives controls by accessibility ID via `probe`/`click`):
  - `display.adaptive_sync` present in controls; toggling stages a draft change
    (`display_changes` increments) and applies through the existing `aq_ready` flow.
  - Headless/unsupported fixture (as with HDR at line 39): switch disabled, help
    text explains why.
  - Fullscreen-only checkbox disabled when master toggle off; enabled when on.
  - Mirrored output: switch disabled with mirroring help text.
  - Fixtures: `tests/fixtures/aqueous-080/snapshot.json` et al. may need
    `support.vrr` / `adaptive_sync` fields if absent.
- **Backend:** no changes needed — `Aqueous/settingsApplication/tests/backend/test-display-mutations.py`
  already covers VRR TOML round-trips (~107–113, 236–246).
- **Compositor:** no changes; existing `adaptive_sync_policy` / output-retry tests stand.

## Manual verification

1. `./launch_aqueous_pearl.sh` on a VRR-capable monitor: toggle Adaptive sync on →
   Apply → confirm `~/.config/aqueous/outputs.toml` gains `adaptive_sync = true`,
   `aqueousctl` reports "Adaptive Sync: enabled", and `actual_vrr` becomes true.
2. Toggle fullscreen-only: VRR effective only with an active fullscreen surface
   (verify via `effective_adaptive_sync` / `aqueousctl` JSON).
3. Non-VRR monitor: switch disabled with "does not support" help; declaration
   editor still allows store-only edits.
4. Mirroring: switch disabled; unmirror restores it.
5. Draft flows: stage without applying, Rebase draft, Validate, and preview
   revert/authorize path behave like HDR edits.
6. Unsupported-preview backend: apply blocked with the warning banner, matching HDR.

## Risks / open questions

- **Preview feature gating:** VRR previews are feature-gated
  (`display_preview_feature_policy_v1`, acceptance builds — see
  `Aqueous/docs/physical-display-preview.md`, `vrr_unsupported` rejection codes).
  On such backends the toggle will be disabled/blocked exactly like HDR; the
  declaration editor remains the escape hatch. Confirm this is acceptable for #159
  or whether store-only apply should be allowed from the simple panel (would need
  helper/preview-policy discussion — out of scope here).
- **`fullscreen_only` default:** confirm the compositor's unset-default before
  fixing the checkbox fallback (step 5).
- **Placement divergence** from `AQUEOUS_DISPLAYS_IMPLEMENTATION_PLAN.md:109`
  (which anticipated adaptive sync under "More display options"): intentional,
  driven by #159's discoverability complaint; update that doc when implementing.

## Out-of-repo follow-up

When implemented and verified, comment on Aqueous#159 referencing the Pearl change
and close (or leave open until the Pearl release ships, per maintainer preference).
