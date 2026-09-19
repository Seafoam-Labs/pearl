# Workspace widget display modes

Status: implemented. This document records the approved behavior and implementation checklist.

## Intended behavior

Add a **Display mode** selection to **Settings → Bar & dock → Workspaces → ⋯**.

| Mode | Workspaces shown | Example: workspace 5 active out of 1–9 |
| --- | --- | --- |
| Small | Active + one existing workspace on each side | 4 **5** 6 |
| Medium | Active + two existing workspaces on each side | 3 4 **5** 6 7 |
| Large | All existing workspaces on this display | 1 2 3 4 **5** 6 7 8 9 |

Use **Large** by default to preserve the current behavior. These modes change the number of workspace buttons, not bar thickness or button size.

Behavior decisions:

- Use the bar's own display and its active workspace. Each display calculates its visible range independently.
- Neighbors mean adjacent entries in the existing sorted workspace list, including when workspace numbers have gaps. With workspaces `1, 3, 7, 9` and `7` active, Small shows `3, 7, 9`.
- Clip at the beginning and end; do not wrap or fill unused positions from the opposite side. With workspace 1 active, Small shows `1, 2` and Medium shows `1, 2, 3`.
- If fewer workspaces exist, show only those available. An empty list renders no buttons.
- If the active workspace cannot be resolved in this display's list, temporarily show all until valid state arrives.
- Recalculate when the active workspace, workspace list, or mode changes, including switches made through keyboard shortcuts.
- Preserve active styling, urgent styling, labels, tooltips, accessibility, and click activation for visible buttons. Urgent workspaces outside the selected range stay hidden.
- Removing the widget retains its mode preference for when it is added again.

## Settings sketch

```text
Bar & dock
  Left group
    Workspaces                         [⋯]
      ┌──────────────────────────────────────┐
      │ Workspaces                           │
      │ Display mode                         │
      │ ○ Small   · Active + 1 on each side   │
      │ ○ Medium  · Active + 2 on each side   │
      │ ● Large   · All workspaces           │
      │                                      │
      │ Move earlier                         │
      │ Move later                           │
      │ Move to…                             │
      │ Remove widget                        │
      └──────────────────────────────────────┘

  Example preview · Medium · workspace 5 active
                      3  4 [5] 6  7

  Unsaved changes                   [Discard] [Apply]
```

Use mutually exclusive controls with accessible selected state and keyboard navigation. Choosing a mode updates the shared draft and example preview; Apply updates the live bar. Reuse the existing Apply/Discard flow. Label the example clearly so it is not mistaken for live compositor state.

## Implementation steps

### 1. Add a pure visibility policy and preference

- Create `src/desktop/workspace_policy.zig` with `Mode = enum { small, medium, large }` and a pure `visibleRange(count, active_index, mode)` helper returning an exclusive-end range.
- For a valid active index, Small uses radius 1 and Medium radius 2: start is `max(0, index - radius)` and end is `min(count, index + radius + 1)`. Implement with safe unsigned bounds; avoid underflow and overflow.
- Large returns the full range. Empty input returns an empty range. Missing or out-of-range active indices return the full range.
- In [preferences.zig](../src/config/preferences.zig), add `workspace_mode: workspace_policy.Mode = .large` to `Bar`.
- Keep preferences version 1: the field has a default, so existing documents remain valid. Strict enum parsing must reject unsupported values.
- Example fragment to merge into an existing bar object: `"workspace_mode": "medium"`.
- Preserve the existing output override semantics: `outputs[].bar` is a complete override. Its omitted `workspace_mode` defaults to Large, even if the global bar uses Small. Display overrides remain editable in Advanced.
- Register the policy module in [src/tests.zig](../src/tests.zig) so its pure tests run.

### 2. Apply the range when rendering the bar

- In [bar.zig](../src/desktop/bar.zig), store the configured mode, initially Large, and add a setter that invalidates the workspace render cache when it changes.
- In [manager.zig](../src/ui/surfaces/manager.zig), pass the resolved `forOutput(...).workspace_mode` to each bar alongside its existing groups/islands settings. Apply it before the next render, including when the group strings have not changed.
- In `Bar.update()`, obtain the existing output-local sorted list from `Model.workspaces()`. Resolve `Model.activeWorkspace(self.output)` and find its opaque ID in that list, then call the range helper.
- Build workspace buttons from the selected slice. Keep activation based on the original opaque workspace ID, with the existing owned callback storage. Do not retain borrowed model pointers beyond the update.
- Hash the mode and visible workspace IDs, numbers, names, active state, and urgency. Include the resolved active identity when relevant to rendering, so a workspace switch cannot leave stale buttons or highlights. Handle an empty range by clearing previous buttons.
- Keep `layoutWorkspaces()` and `fitTasks()` after rendering. Existing horizontal wrapping and vertical stacking should operate on the visible subset, and Running applications should gain the freed space.
- Leave the compositor model and workspace creation/deletion behavior unchanged. The bar remains non-keyboard-interactive under its existing surface policy.

### 3. Connect the widget menu to the shared draft

- In [bar_model.zig](../src/settings/bar_model.zig), add a dedicated `patchWorkspaceMode(...)` helper. Parse the latest document, require the Workspaces widget to still be present, change only `document.bar.workspace_mode`, validate, serialize, and enforce the existing document-size limit.
- Keep layout movement actions in the existing `Action` type; the new helper handles widget configuration independently.
- In [bar_view.zig](../src/settings/bar_view.zig), add a mode-change intent and render the three choices only in the Workspaces action menu. Show the selected mode in the widget row so it is visible when the menu is closed.
- Reuse the existing editable-state checks and `popup_hash` stale-menu check before mutation. Submit through `editor.edit(...)`, announce the selected mode and unsaved state, and return focus to the Workspaces action button.
- Show a compact example in the draft preview using workspaces 1–9 with 5 active. Use the same policy helper so the preview matches runtime behavior.
- Keep the selector in the widget menu; no duplicate control is needed in `preference_pages.zig`. Keep existing move/remove controls available.

### 4. Add focused verification

| Area | Checks |
| --- | --- |
| Range policy | All modes; middle, first, and last active positions; zero/one/two workspaces; missing and invalid active index |
| Workspace identity | Sparse numbers; deterministic sorted adjacency; buttons retain the correct activation IDs |
| Preferences | Existing documents default to Large; each mode round-trips; invalid values fail; complete display overrides retain existing semantics |
| Draft mutation | Only the mode changes; layout, plugins, output overrides, and unrelated preferences survive; missing widget is rejected |
| Settings | Selected state, keyboard selection, preview, Apply, Discard, reopen/restart persistence, stale menu rejection |
| Live bar | Switch active workspace across both boundaries by click and external shortcut; create/remove workspaces; independent displays |
| Layout | All four edges, narrow bars, larger fonts/scales, and Running applications reclaiming freed space |

Extend [test_settings_bar_editor.py](../tests/integration/test_settings_bar_editor.py) for menu/draft behavior and [test_bar_layout.py](../tests/integration/test_bar_layout.py) for mode rendering. Preserve its existing all-workspace assertions for Large. If native inspection currently reports only button rectangles, extend the test report with workspace IDs/numbers to verify the actual subset and activation targets.

Run these checks after implementation:

```bash
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-settings-bar-editor -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-bar-layout -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-preferences -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-running-apps -Doptimize=ReleaseSafe
```

The native integration targets require the repository's private Aqueous test environment and permission to create local sockets.

### 5. Document and finish

- Update [PREFERENCES.md](PREFERENCES.md) with the enum, default, JSON example, and output override behavior. Older binaries use strict parsing and may reject the new field; remove it before downgrading.
- Update [DESKTOP.md](DESKTOP.md) with the menu location, examples, edge clipping, and per-display scope.
- Capture the Settings selector and live bar in each mode for review.

Acceptance: Small shows at most three workspace buttons, Medium at most five, and Large shows all when the active workspace is known. Changing active workspace moves the visible range immediately. Existing configurations retain Large behavior, and Apply/Discard and restart persistence work through the existing settings system.
