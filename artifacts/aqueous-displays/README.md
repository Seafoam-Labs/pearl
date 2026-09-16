# Native Aqueous Displays implementation

The native Settings page implements the [approved design](../../docs/mockups/aqueous-displays/index.html)
and [implementation plan](../../docs/AQUEOUS_DISPLAYS_IMPLEMENTATION_PLAN.md).

The main page has numbered selectable/dragged screens, paired selected-display
and Position cards, resolution/refresh/scale/orientation controls, an automatic
HDR checkbox, and a fixed Discard / Apply changes footer. Exact coordinates and
advanced display/HDR configuration are collapsed. Identify uses transient labels
on actual outputs owned by the Pearl session service. Applying uses the existing
canonical validation, preview lease, presentation acknowledgement, protected
save, and rollback lifecycle.

## Captures

These are native GTK captures from isolated headless Aqueous sessions. Headless
outputs correctly report HDR as unsupported; they are not evidence of HDR hardware
support. Names and modes reflect the test outputs rather than the mockup's sample
monitor names.

- [Desktop](session/desktop.png)
- [Unsaved settings](session/unsaved.png)
- [Keep / Revert confirmation](session/confirmation.png)
- [Identify on the host output](session/identify.png)
- [Shared-draft review](session/shared-draft-review.png)
- [Narrow selected-display editor](session/narrow.png)
- [Advanced controls](session/advanced.png)

## Verification

The focused [native interaction report](verification.json) covers actual pointer
dragging and keyboard movement, selection, source-bound drafts, exact position,
relative arrangement, scale, navigation, disclosures, unsupported HDR, Identify
surface creation/cleanup, Keep/Revert, cancellation of shared-draft review, and
narrow layouts. The test target is `zig build test-settings-displays`.

All 116 pure tests pass. The 14 focused native interaction checks pass.

Pure tests cover logical geometry and snapping, fractional scale and reflected
rotation, declaration coalescing, profile member isolation, automatic HDR/reset,
retaining unrelated edits, raw-file conflicts, and stale generations.

[Combined verification summary](summary.json).

One service run timed out awaiting a second preview after closing/reopening the
frontend. The subsequent isolated run passed all 26 checks. The service test now
reports backend preview state on a timeout to make any recurrence diagnosable.

Regression results:

- [Standalone window](window/results.json)
- [Settings services](services/report.json)
- [Presentation, themes, scaling, and output removal](presentation/results.json)
- [Aqueous configuration and receipts](aqueous/metadata.json)
- [Native preview lifecycle](preview/metadata.json)
- [Installed application and CLI integration](integration/results.json)
- [Surface lifecycle, CLI isolation, and native GTK blur](surfaces.log): `zig build test-surfaces`.
- [Production build](build.log) and [pure suite](pure-tests.log): `zig build` and `zig build test`.

## Backend limits

Production DRM/HDR preview availability remains determined by the pinned Aqueous
backend. This frontend preserves its store/test/preview gates and cannot enable
an unsupported live HDR preview. Automatic HDR mutation behavior is covered by
pure tests; enabling HDR on physical hardware still needs a backend with the
required native preview support and a real HDR-capable monitor.

Profiles that cannot be uniquely identified in the editable outputs source are
handled by the retained advanced declaration editor. New primary controls never
silently edit a shared wildcard/profile declaration.
