# Remaining Aqueous dependencies

Inspected source baseline: `1d038dc3bafa0044d9599f8f51f84105a6a85bb3`, helper
0.8.0, protocol 1. These are limits of that exact implementation, discovered
while implementing the master update. Pearl must not bypass them. Source paths
below are relative to the pinned Aqueous repository.

## Structured display mutations

`settingsApplication/src/backend/operations.zig:applyMonitorChanges` accepts
only identity/name, position, transform, mode, scale and `mirror_of`. The helper
exposes complete parsed declarations but has no structured mutation for enabled,
primary, identity matching, profile CRUD/membership, HDR/VRR or inheritance.
Unknown monitor-change keys are not proof that these settings were changed.

Add a negotiated declaration mutation contract with generation-scoped IDs,
explicit unset versus false/zero, profile operations, source selection and
conflict checks against raw files. Return canonical candidate sources and the
existing digest/impact/projection. The helper must remain the only TOML editor.
Test duplicate declarations, offline and disabled outputs, inherited values,
profile ordering, malformed IDs, external reorder and raw/structured overlap.
Pearl currently shows the full observation and disabled controls with the reason;
Advanced raw edits still pass through protected validation and native previews.

## Complete candidate classification for collections

`settingsApplication/src/backend/impact.zig:prepare` recognizes display keys and
scalar `schema.fields`; it does not use the rule/custom-binding/named-layout
schemas when classifying non-display changes. A valid structured rule or shortcut
can therefore validate successfully and still have `complete:false` and effect
`unknown`. Protected apply correctly rejects it. This is reproducible with a rule
`{app_id:"pearl-test-*",floating:false,opacity:0.8}`.

Classify canonical collection mutations through their semantic schema, including
add/delete/move, null removal, repeated rules, custom command arguments and named
snap geometry. Preserve uncertainty for unknown extensions and ambiguous raw
source. Validate both original and candidate semantics. Keep mixed display changes
on the display path. Test each collection operation, malformed extensions and
multiline/raw mixtures. Do not solve this by declaring every rules/wm/layout file
non-display or trusting a caller-supplied classification.

`collection_preconditions` can permit a stale generation for collection-only
requests, but its current allowlist excludes `protected_apply` and
`candidate_digest`. Pearl explicitly rebases against a fresh snapshot only when
the affected collection source is unchanged; it cannot use stale indices to
bypass protected apply. Upstream should make these contracts composable while
retaining fresh candidate validation and digest binding.

## Isolated-source color metadata

`compositor/patches/wlroots/0015-ext-capture-formats-and-color.patch` and
`compositor/protocol/aqueous-capture-color-v1.xml` allow `unavailable` for scene
sources. `Server.zig:handleToplevelCaptureRequest` creates a scene source. Pearl
selects the real foreign-toplevel source; it never substitutes an output crop.
If no usable encoding arrives before frame ready, PNG export is withheld.

Provide destination color metadata for the scene source's actual copied pixels,
including any SDR conversion. Do not infer transfer function or gamut from the
buffer's bit depth. Test overlapping unrelated windows, protected/unmapped
sources, SDR reference samples, HDR input converted to SDR, and source destruction
before ready. Pearl accepts described sRGB-primary SDR, converts gamma 2.2 to
sRGB, and rejects unsupported gamut/transfer metadata.

## Physical display previews

`compositor/aqueous/DisplayPreview.zig` rejects non-headless protected previews;
HDR and VRR changes remain gated, and mirroring depends on renderer support.
`store:true` does not authorize an unprotected save, even for deferred outputs.
Hardware backend testing and crash-safe rollback acceptance remain upstream work.
No automated headless evidence in Pearl constitutes hardware acceptance.

## Packaging

The helper-only build succeeds without the retired GUI. The upstream distribution
package still depends on Dank Material Shell and enables its service. Aqueous
packaging should split the shell-independent compositor/helper from an optional
shell/session preset. Pearl packages must not automatically replace the user's
shell, enable DMS, install the old settings GUI or alter host configuration.
