# Remaining Aqueous dependencies

Current source: `88587243059d58d72dd0fe2146d0ebdb64f26474`, helper 0.8.2,
protocol 1. See [implementation](AQUEOUS_082_UPDATE_PLAN.md) and
[integration evidence](../artifacts/aqueous-082/README.md).

See also [input activity integration](AQUEOUS_PLUGIN_ACTIVITY.md) and its
[validation record](PLUGIN_INPUT_ACTIVITY_VALIDATION.md).

## Resolved in this integration

- Structured display declaration mutations now support enablement, primary,
  identity matching, profiles/membership, inheritance and HDR/VRR configuration.
  Pearl exposes them as typed drafts, with native capability restrictions on apply.
- Canonical collection classification and protected v2 source preconditions now
  permit safe rule, shortcut and snap-layout persistence. Mixed requests retain
  the ordinary fresh-generation native display contract.
- Supported isolated scene sources now report destination color metadata; Pearl
  exports described SDR pixels and rejects unavailable/unsupported encodings.
- Upstream core packaging contains compositor/helper/library, with separate optional
  session and shell integrations. Pearl does not require DMS activation.

## Physical display acceptance

Night Light also requires live, output-bound color eligibility with enforcement
at application time. Current gamma advertisement lacks HDR/calibration state and
cannot guard writes against a changing color path. Pearl exposes preferences and
status but acquires no gamma controls. See [the required contract](NIGHT_LIGHT.md#aqueous-prerequisite).

`compositor/aqueous/display_preview_policy.zig` still has no production DRM
acceptance. The separate `-Ddisplay-preview-acceptance=true` build and exact
`AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_OUTPUTS` selection permit SDR acceptance tests.
HDR/VRR, DRM mirroring and custom modes remain separately unavailable. Headless
mirroring depends on renderer support. Stored declarations and successful validation
cannot authorize bypassing a preview lease. Physical tests require a separate
hardware session; headless results do not establish hardware acceptance.

## Lost preview-begin reply

Native preview status/revert require the compositor-generated token. If the begin
reply is lost before Pearl receives that token, there is no lookup by client operation
ID or candidate digest. Pearl records the intent and reports uncertainty. A changed
compositor session invalidates the old lease; until then it blocks subsequent saves.
Upstream could add a session-bound request identity/status lookup to resolve this
case without requiring a new session. Known tokens are reconciled across Pearl restarts.

## Unproven capture paths and ambiguous source syntax

Scene metadata can remain unavailable for unsupported renderer/copy/conversion
paths. Pearl does not infer transfer function or gamut from bit depth.
The helper rejects ambiguous display source surgery, unknown extensions and
unsupported encodings. Advanced remains available for canonical raw repair;
unknown candidate impact still blocks persistence.
