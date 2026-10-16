# Plugins interactive mockup

Open [index.html](index.html) directly in a browser. No server, build, dependencies,
network requests, or browser storage are needed. All changes are in memory;
reloading resets the sample. Keep the mockup in the repository so the existing
CC0 [Pearl Cat artwork](../../../plugins/examples/companion-c/cat.svg) resolves.

This proposal brings Plugins into the current Pearl Settings design, following
[Appearance](../../APPEARANCE_REDESIGN_PLAN.md) and
[settings-layout.css](../../../resources/settings-layout.css): 16 px card corners,
20 px card insets, 30 px desktop / 16 px narrow content margins, clear status
summaries, progressive disclosure, and a persistent shared preferences footer.
HTML, CSS and JavaScript are used under the repository's mockup exception.
The corresponding [native Zig implementation and captures](../../../artifacts/plugins-layout/README.md)
are tracked separately; this directory remains an offline design prototype.

## Try it

- Review and approve Counter (Zig), enable it, then Apply & save.
- Expand Pearl Cat's Settings & placement; switch between Bar and Desktop overlay,
  edit geometry and display, or change activity and overlay permissions.
- Edit Countdown's starting seconds; try Preview, Reset settings, Apply and Discard.
- Retry the stopped Counter (Rust). Retry and Preview use saved preferences and
  act immediately in the simulation; Discard does not reverse a retry.
- Search by name or package ID and filter by draft enablement or attention needed.
- Refresh discovery while a draft is pending; the draft stays intact.
- Switch the preview scenario to updated, missing, unavailable or empty packages.
  Scenario changes reset sample preferences. Updated packages need fresh review;
  missing packages retain preferences and can be disabled.
- Switch light/dark appearance. On narrow screens, Sections opens navigation.

Direct states: `?theme=light`, `?view=details`, `?view=review`, and
`?state=changed|missing|unavailable|empty` (choose one state).

## Captures

| View | Screenshot |
| --- | --- |
| Dark desktop | [desktop.png](desktop.png) |
| Light desktop | [light.png](light.png) |
| Expanded placement | [details.png](details.png) |
| Permission review | [review.png](review.png) |
| Updated package | [changed.png](changed.png) |
| 560 px layout | [narrow.png](narrow.png) |
| 390 px layout | [compact.png](compact.png) |
| 390 × 600 review | [review-compact.png](review-compact.png) |

## Validation and scope

Run `python3 docs/mockups/plugins/verify.py` from the repository root with the
Python Playwright package and `/usr/bin/chromium` installed. It refreshes the
captures and [verification.json](verification.json). All 35 checks passed,
including approval gating, draft/apply/discard, permission and placement
coupling, saved-setting previews, immediate retry, numeric validation after
filtering, empty/error states, Escape/focus restoration, and overflow at 390 and
560 px. Dark, light and compact captures were visually reviewed.

This is a layout and interaction proposal, not a native runtime or accessibility
certification. The four packages match the repository examples, but descriptions,
fingerprints, paths and runtime states are illustrative. It does not execute
Wasm, read installed packages, persist preferences, or implement cross-page
drafts, conflict merging, package races, native focus reconciliation or backend
validation. Search filters the sample inventory; native integration would need
to account for the existing paginated discovery API. Sidebar links open existing
mockups where available; other destinations are context labels.

Production behavior is documented in [PLUGINS.md](../../PLUGINS.md). Enabling a
reviewed plugin in Bar mode adds it to the bar when applied. Explicit overlay
selection grants overlay permission; revoking that permission returns it to the
bar. Approval does not automatically enable a newly installed plugin. Status
badges describe saved runtime state; draft changes are marked separately.
