# Bar autohide

Status: implemented and verified. This document records the behavior and scope.

Add **Bar visibility → Always visible / Autohide** to **Settings → Bar & dock**.
Autohide gives applications the full available desktop and reveals the bar when
the pointer reaches its configured screen edge.

## Behavior

- Default to **Always visible**, preserving the current bar and reservation.
- In **Autohide**, start hidden, reveal immediately on edge entry, and hide
  450 ms after the pointer leaves the bar and reveal strip. Re-entry cancels
  the pending hide. Use the dock's existing delay as the initial constant.
- Use a transparent, 2-logical-pixel reveal strip along the output's full bar
  edge. It works for top, bottom, left and right, including island layouts.
  Keep the strip mapped while autohide is active; all input outside it and the
  visible bar retains the existing input-region behavior.
- Autohide reserves no work area, including while temporarily revealed, so
  revealing the bar never resizes application windows. Always visible restores
  the measured reservation. Configured thickness remains independent of the
  active reservation.
- Hold the bar open while a principal Pearl popup on that output is open, or
  while a bar-owned menu or active pointer gesture requires it. Begin the normal
  hide delay after the final hold ends. Moving between islands, into a popup,
  or through the small gap at the edge must not interrupt interaction.
- Allow edge reveal above fullscreen applications, using the dock's existing
  fullscreen layer-switching pattern. Restore the normal layer afterward.
  Lock/session inhibition overrides reveal and all interaction holds.
- Keep the bar's keyboard mode `none`. Existing launcher, running-apps and
  control-center commands remain usable when it is hidden; opening their popup
  reveals and holds the corresponding output's bar. The standalone Settings
  application does not hold the bar open for its entire lifetime.
- Apply & save changes the running bar without a restart. Draft changes and
  Discard follow the existing shared editor transaction. Switching to Always
  visible cancels timers and removes the reveal strip immediately.
- Ship immediate visibility changes initially. Animation, configurable timing,
  intelligent window-overlap hiding and new keyboard-focus commands are deferred.

## Preference contract

Add `mode: enum { always, autohide } = .always` to `Bar` in
[preferences.zig](../src/config/preferences.zig). Example:

```json
{ "bar": { "mode": "autohide" } }
```

Keep preference version 1. Missing fields resolve to `always`; reject unknown
modes and invalid types. Apply the same field to `outputs[].bar`, preserving
`forOutput`'s complete bar replacement semantics: an output override with no
`mode` uses `always`, even if the default bar uses `autohide`. The regular form
edits the default bar; display overrides remain editable in Advanced. Preserve
unrelated values during patching, merging, saving and reload.

## Implementation sequence

1. **Model the policy and transitions.** Add a small pure
   `src/desktop/bar_visibility.zig` module for mode, visibility reasons and
   transitions driven by pointer presence, interaction holds, inhibition and
   hide deadlines. Distinguish pointer presence on the sensor and bar so a late
   leave event cannot hide a newly entered surface. Use one cancellable,
   one-shot GLib timer per output, with no idle polling. Add preference and
   policy tests and register the module in [tests.zig](../src/tests.zig).

2. **Separate geometry from reservation.** Update the surface manager's
   `sizeEdge`, `measured`, preference reconciliation and `bar set` handling in
   [manager.zig](../src/ui/surfaces/manager.zig). Both sizing functions currently
   write the exclusive zone directly; route bar writes through one mode-aware
   helper so measurement cannot accidentally restore an autohide reservation.
   Use the existing dock convention of exclusive zone `-1` for the overlay bar
   and sensor. Keep frame behavior intact. In
   [policy.zig](../src/ui/surfaces/policy.zig), retain bar edge ownership and
   thickness even when it reserves nothing: frames still cannot occupy that
   edge, and the dock still avoids the bar's configured edge.

3. **Own reveal surfaces and runtime state.** Attach a controller to each
   output's bar surface in the manager. Follow
   [dock.zig](../src/desktop/dock.zig) for transparent-buffer mapping, monitor
   association, motion controllers and destruction. Give the sensor namespace
   `pearl:bar-reveal`, overlay layer, no keyboard input and no reservation.
   Keep [bar.zig](../src/desktop/bar.zig) responsible for bar content. Hiding
   should unmap its window without destroying widgets or services. Configure
   visibility before first presentation to avoid a startup flash. Rebind
   measurement/frame-clock callbacks after remapping as needed, and verify
   native input and blur effects reattach through their existing lifecycle.
   If sensor setup fails, retain a visible usable bar and report the failure.

4. **Connect interaction and lifecycle.** Acquire/release output-specific holds
   in `showPane`/`hidePopup`, including popup replacement and failed creation.
   Connect bar-owned gesture/menu lifetimes where applicable; release holds on
   content reconstruction. Use the shell's authoritative session/inhibition
   gate to cancel deadlines, hide autohide surfaces and prevent reveal during
   lock, authentication and session transitions. Output removal and manager
   teardown must disconnect callbacks and remove timers before freeing state.
   Reconcile edge, size, mode, scale and output changes while hidden as well as
   visible. Re-evaluate current pointer presence after enabling autohide or
   unlocking instead of retaining stale hover state.

5. **Place popups and expose status.** Autohide leaves Aqueous usable bounds
   unreserved, so existing edge-anchored placement can overlap the revealed bar.
   Derive popup placement bounds from current usable bounds and the measured
   bar footprint, accounting for other reservations without subtracting the
   bar twice. Apply this to anchored popups; preserve centered placement and
   clamp correctly on small outputs. Verify backdrop input does not swallow
   the initiating bar click or cause reveal/hide loops. Audit OSD/notification
   positioning for overlap on the bar's edge. Extend output status with
   `bar_mode`, `bar_visible`, `bar_visibility_reason`, `bar_sensor_visible` and
   `bar_exclusive_zone`; retain `bar_size` as thickness for existing consumers.

6. **Add settings and documentation.** Extend `bar_fields` in
   [preference_pages.zig](../src/settings/preference_pages.zig) with the visibility
   choice and helper text explaining edge reveal and display overrides. Use
   accessible labels and the existing draft, error and read-only states.
   Verify keyboard selection, Apply, Discard and reopening. Document the field
   and reservation behavior in [PREFERENCES.md](PREFERENCES.md),
   [SURFACES.md](SURFACES.md) and [DESKTOP.md](DESKTOP.md).

7. **Verify in a private Aqueous session.** Add
   `tests/integration/test_bar_autohide.py` and a `test-bar-autohide` build target.
   Capture status, usable bounds, input results and representative screenshots
   under `artifacts/bar-autohide/`. Use observable conditions and bounded waits
   for runtime checks; test timer boundaries deterministically in the pure
   policy tests.

## Acceptance checks

- Legacy documents and Always visible retain their layout, input and measured
  reservation. Autohide round-trips globally and per display; invalid values
  fail without modifying the last good configuration. Drafts preserve unrelated
  settings and support normal conflict handling.
- Edge entry reveals the correct output; leaving hides after the delay;
  re-entry cancels hiding. Repeated events and stale timer callbacks cannot
  dismiss an active bar. Popup/gesture holds compose and release correctly.
- Real application usable bounds expand when autohide is enabled and remain
  identical while revealing/hiding. Returning to Always visible restores the
  measured zone, including after font or thickness changes.
- Continuous and island bars work on all four edges, including transparent
  gaps, scaled/rotated outputs, negative origins and adjacent monitor edges.
  Hidden content cannot intercept clicks beyond the sensor. Visible content,
  running-apps actions and tray menus remain operable.
- Fullscreen reveal works; lock and session loss disable the sensor. Unlock,
  output hotplug, reconnect, edge changes and preference reload recover without
  ghost surfaces, retained holds, invalid callbacks or startup flashes.
- Two displays can use different modes. Popup replacement across displays
  releases the previous hold. Anchored and centered popups remain accessible
  on small outputs; dock, frames, OSD and notification behavior stays correct.
- Settings covers mouse/keyboard selection, draft isolation, Apply, Discard,
  reopening and persistence after restart. Existing shell commands work with
  a hidden bar and retain popup keyboard focus.

Run `zig build test -Doptimize=ReleaseSafe`, the new `test-bar-autohide` target,
and affected integration targets: `test-settings-bar-editor`, `test-preferences`,
`test-surfaces`, `test-bar-layout` and `test-dock-islands`. Use the repository's
documented local Zig cache setup. Inspect GTK/Wayland diagnostics during repeated
hide/show and hotplug cycles.

The first runtime milestone must prove that a fully unmapped bar can reliably
remap from its sensor, including above fullscreen clients, and that usable bounds
stay stable across reveal. Resolve any compositor-specific mapping or input
ordering issue there before completing settings integration.

## Verification results

- ReleaseSafe build and all 174 pure tests pass, including visibility deadlines,
  interacting holds, inhibition, preference defaults/overrides, merge behavior
  and popup footprint geometry.
- The complete autohide suite passes 21 checks against the existing surface-test
  compositor, including real edge input on all four edges, fullscreen clicks,
  stable maximized-window geometry, popup holds, click-through regions, mixed
  geometry, output removal, mode changes and restart.
- The newer cached Aqueous build passes the other 20 checks. Its existing
  `OutputManager.validateConfigCoordinates` assertion prevents output-disable
  testing; reproduce that run with `--aqueous
  .cache/aqueous-activity-production/bin/aqueous --skip-hotplug`. The default
  target includes hotplug against the working surface-test baseline.
- Settings bar editor: 18 checks; preferences: 25; surfaces: 19; dock/islands:
  17; bar layout/opacity: 45 cases. All passed during implementation.
- Runtime testing found stale GTK motion-controller crossing state after a
  hovered sensor unmaps. Replacing the controllers on mode, edge or inhibition
  changes restores reliable entry after reactivation. Popup destruction on
  inhibition runs from the manager's idle reconciliation, preserving the
  lifetime of a button callback that initiated locking.

See [verification artifacts](../artifacts/bar-autohide/README.md) for reports,
screenshots and the compositor-specific test limitation.
