# Global window switcher and cursor warping

Status: implemented in coordinated local Pearl/Aqueous changes.
Builds, native checks, and coverage limits are recorded in the
[evidence directory](../artifacts/global-window-switcher/README.md).

Extend the existing Cycle windows feature to visit eligible windows on every
workspace and enabled output. Selecting a window activates its own workspace,
selects its output for the initiating seat, and focuses it without moving the
window. Move the cursor into the selected window when the switcher finishes.

This is a follow-up to [the delivered workspace switcher](WINDOW_SWITCHER_IMPLEMENTATION_PLAN.md).
It replaces that feature's workspace-only scope on capable Aqueous versions.

## Behavior

- Use one stable global order per seat and compositor session. Include windows
  on inactive workspaces and other outputs; visibility is not an eligibility
  filter. Preserve the existing exclusions for minimized windows, shell
  surfaces, non-activatable windows, `skip_switcher`, and modal-blocked parents.
  Include obscured and `skip_taskbar` windows. Exclude windows with no valid
  workspace/output and windows on disabled or unavailable outputs.
- Keep immediate selection: every next/previous action focuses one window;
  there is no new Enter-to-confirm interaction. Activate only the destination
  output's required workspace. Never transfer a window between outputs or
  workspaces, or alter its saved geometry, layout, or fullscreen state.
- Keep the deck and Pearl HUD on the initiating output throughout a cycling
  session, even when focus moves elsewhere. Display the selected title,
  workspace, output name, and global position/count. After dismissal, the next
  invocation uses its new initiating output but resumes the same ring.
- A bar identifies the presentation output; native shortcuts use the initiating
  seat's output when opening the switcher. Subsequent shortcut presses retain
  that presentation output. `--output` identifies presentation, not filtering.
- Empty global set: disable the button. One global window: allow activation,
  including when it lives on an inactive workspace or different output, and
  perform the cursor handoff without showing a redundant cycling deck. Remove
  both the current `n > 1` button restriction and compositor one-window no-op.
- Retain forward/reverse wrap, 1.5-second idle dismissal, reduced motion, and
  stable order across dismissal. Append newly eligible IDs deterministically;
  moving an eligible window between workspaces/outputs does not reorder it.

### Cursor handoff

Delivered timing: warp after the deck closes, when the real selected window
is visible and its destination geometry is committed. Cycling updates focus
immediately, but repeated selections replace one pending warp target. This
keeps the bar/HUD controls usable and avoids moving onto an animation clone.

Idle dismissal, Escape, explicit dismiss, and typing finish the selection and
request the warp. Escape keeps the selected window, matching existing behavior.
Physical pointer motion or a click outside the controls cancels the pending
warp, allowing the user's pointer action to win. Pointer activation of a
switcher button schedules its handoff after button release; do not cancel that
new request merely because the initiating click still has a button held.

Use the selected window's visible content center, with the existing hit-tested
inset points as fallbacks. Leave the cursor alone if it is already over the
selected window. Use logical layout coordinates, including negative output
origins, fractional scaling, and rotation. If no valid input point exists,
retain keyboard focus and skip the warp rather than landing on another client.

The switcher warp is explicit feature behavior and works with
`mouse_follows_focus` either enabled or disabled. Ordinary focus behavior keeps
its existing preference. Never warp during lock, drag, resize, or an unrelated
pointer grab; cancel invalidated requests rather than replaying them later.
External focus/workspace changes, selected-window destruction, output loss,
IPC owner disconnect, and teardown dismiss without warping.

## Current implementation and changes required

Paths in the Aqueous column are relative to `/home/zoey/RiderProjects/Aqueous`.

| Component | Existing behavior / required change |
| --- | --- |
| Pearl `src/desktop/window_switcher.zig` | `eligible`, `count`, and `action` require the invoking output's active workspace. Add capability-aware global membership/count and commands. |
| Pearl `src/aqueous/commands.zig`, `codec.zig`, `entities.zig` | Commands require a matching active workspace; capability and session metadata describe the workspace switcher. Extend validation, serialization, capability decoding, and authoritative state. |
| Pearl `src/desktop/bar.zig`, `src/settings/bar_model.zig` | Count, disabled state, descriptions, and translated tooltips say “this workspace.” Update for the negotiated scope. |
| Pearl `src/ui/surfaces/manager.zig` | HUD derives workspace from its presentation output. Read the selected window's destination instead and preserve presentation ownership. |
| Aqueous `compositor/aqueous/WindowSwitcher.zig` | Rings are keyed by workspace; `step` and `validate` require the same active workspace and selected output. Introduce global membership and separate presentation from destination. |
| Aqueous `compositor/aqueous/wm/switcher/model.zig` | Reuse stable `Ring` ordering and card layout; test global membership churn. |
| Aqueous `compositor/aqueous/wm/Aqueous.zig` | `activateShellWindow` already selects the target output/workspace and requests seat focus. Reuse this activation path with explicit switcher transition tracking. |
| Aqueous `compositor/aqueous/Overview.zig` | Deck reuses texture cloning and hides the presentation output's active workspace. Handle inactive-workspace sources and workspace changes without restoring stale visibility. |
| Aqueous `compositor/aqueous/Seat.zig`, `Cursor.zig`, `WindowManager.zig` | Focus warps finish after scene commit, but are preference-gated and hit-test live surfaces. Add an explicit switcher handoff using the existing geometry and safe warp helpers. |
| Aqueous `ShellCommand.zig`, `ShellCommands.zig`, `IpcProtocol.zig`, `IpcServer.zig`, `ShellManager.zig` under `compositor/aqueous/` | Extend typed requests, queue cloning, dispatch, capabilities, replies, and session snapshots together. |

## Implementation sequence

### 1. Extend the protocol without changing the old contract

Add capability `global_window_switcher_v1`. Extend `switcher.next`,
`switcher.previous`, and `switcher.dismiss` with `scope: "all"`; omitted scope
retains `workspace_switcher_v1` behavior. For global requests, require a valid
presentation `output` and resolved `seat`, but omit `workspace`. Keep existing
workspace validation for legacy requests. Reject invalid combinations and
unknown scope values; preserve fields through command cloning and queuing.

Pearl requests global scope whenever the new capability is advertised. On older
Aqueous it keeps the existing workspace-only behavior and labels it accurately.
Native switcher bindings use the same global operation in the updated compositor.
No new settings page or shortcut assignment is needed.

Keep `switcher_output` as the presentation output. Add scope, owning seat, and
selected workspace/output IDs to session state and command results. Distinguish
accepted requests from committed focus; serial/session identity must prevent
stale replies from overwriting a newer selection. Global dismiss resolves the
owning presentation and seat, without requiring an obsolete active workspace.
Retain one ordered command stream per seat and never replay steps on reconnect.

### 2. Build and validate the global ring

Enumerate workspaces of every exposed output, apply the authoritative compositor
eligibility policy, deduplicate handles, and reconcile a ring per seat. Retain
legacy workspace rings for old requests. Shell `switcher_eligible` and Pearl's
global count must agree on output availability and modal resolution.

Use the active session's selected handle during a burst and actual seat focus
after dismissal. Preserve existing entries across output/workspace moves;
prune closed, minimized, excluded, and unavailable entries. Clean up rings on
seat removal/session reset. Keep all entries reachable while drawing at most
the selected window and its two neighbors.

The current renderer supports one presentation. Retain that limit explicitly:
a new seat's invocation ends the previous presentation without a warp, then
uses its own ring and focus. Never move another seat's cursor.

### 3. Coordinate activation and presentation

Separate origin/presentation output from selected window destination. Record a
pending selection and expected destination before requesting activation so
`validate` and `Seat.focus` can recognize transitions caused by the switcher.
Only those expected transitions preserve the deck; unrelated changes dismiss.

Prepare/validate card resources before activation where possible. Commit
selection state only after the destination focus is confirmed. A vanished or
unavailable target fails cleanly with no warp and no fabricated success; discard
stale pending work. Each successful step advances once during rapid input.

Prove texture cloning for mapped windows on inactive workspaces and remote
outputs. Supply title/icon placeholders when a client has no usable buffer;
missing preview content must not remove an otherwise activatable window from
the ring. Rebuild source geometry after activation when required.

Audit deck hide/restore across workspace switches on its presentation output:
restore according to current committed visibility, never re-enable the previous
workspace's trees from stale saved flags. Keep source windows on other outputs
in their normal placement. Preserve current animation and reduced-motion rules.

### 4. Add the cursor handoff

Replace undifferentiated dismissal with explicit finish/cancel reasons. Store
seat, selected window ref, and selection generation as the pending warp; replace
it on subsequent steps. Restore the deck, commit live scene geometry, revalidate
focus and output availability, then warp through `Cursor.warpToFocusedWindow`
and `warpForPolicy` using an explicit policy path independent of the automatic
focus preference.

Separate generic safety checks from `Seat.canFollowFocus`'s preference check.
Suppress ordinary automatic warps while the switcher owns the selection, so an
enabled `mouse_follows_focus` cannot race the final handoff. Invalidate pending
work on physical pointer intent, lifecycle cancellation, or a newer generation.
Ensure destination enter/leave and pointer constraints refresh without treating
the warp as physical motion or causing hover focus to select a different window.

### 5. Integrate Pearl and document the contract

Update button counts, single-window activation, translated settings text,
tooltips, and accessible announcements. Show destination workspace and output
even while the HUD stays on the origin output. Keep the HUD keyboard mode `none`.
Global commands must survive their own workspace changes during queued bursts;
do not capture a workspace constraint in the new request shape.

Update protocol fixtures and capability inventory, CLI help, `DESKTOP.md`,
`SURFACES.md`, and Aqueous command documentation. Record the paired versions and
the workspace-only compatibility behavior. Retain the original implementation
plan and evidence as historical records.

## Verification and acceptance

Extend existing meaningful tests rather than adding a separate test framework.

| Area | Required checks |
| --- | --- |
| Global order | 0/1/2/many windows; at least three spread across two outputs and active/inactive workspaces; N forward steps visit N IDs and return to start; reverse, rapid presses, and idle dismissal preserve order. |
| Membership | Obscured, skip-taskbar, modal dialogs, minimized and skip-switcher exclusions; moves preserve order; output disable/removal removes candidates; duplicate workspace names never collide. |
| Activation | Correct seat, output, workspace, and keyboard focus on every accepted step; no migration or saved geometry/layout/state changes; sole remote window remains reachable. |
| Presentation | HUD remains on origin and labels destination correctly; inactive-workspace cards render or show placeholders; workspace changes never reveal stale trees; mixed scale, portrait, negative coordinates, fullscreen, and reduced motion. |
| Cursor | Warp into actual selected content after dismissal with mouse-follows-focus on/off; already-over-target no-op; no warp to deck/HUD; only latest burst target wins; button release, typing, Escape, explicit dismiss, and idle completion. |
| Cancellation | Physical motion/click wins; no delayed warp after drag/grab, external focus change, lock, destruction, IPC loss, seat removal, or output removal; constraints and hover focus remain correct. |
| Compatibility | New Pearl/old Aqueous stays workspace-only; old Pearl/new Aqueous retains v1 behavior; global dismiss and queued steps work after destination changes; stale replies/reconnect never replay. |

Run Pearl's ReleaseSafe unit suite and `test-window-switcher`, plus affected
bar-layout/preferences tests. Run Aqueous compositor tests including protocol,
ring, and focus-warp coverage, then its overview regression script. Extend
`tests/integration/test_window_switcher.py` to distribute real clients across
outputs/workspaces and observe real focus, workspace activation, pointer
coordinates, and pointer target after scene restoration. Validate XDG and
XWayland; record unavailable hardware/multi-seat coverage explicitly.

Save native state, scene captures, and test results under a new
`artifacts/global-window-switcher/` directory during implementation. Build and
test in disposable sessions before changing the user's running desktop.

Acceptance: every eligible window across the desktop is reachable in one stable
cycle; selection opens its existing workspace/output; finishing places the
initiating seat's cursor inside the final window unless physical pointer input
or a lifecycle/safety condition cancels the handoff.
