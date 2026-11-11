# M2: native docks and picker integration

**Implemented:** Explorer and workspace Search now live in movable, resizable, hideable native docks around the central editor. Quick Open uses a transient in-window picker. This is a functional workbench-layout increment, not pixel-for-pixel mockup parity or a complete IDE. No placeholder Git, agent, terminal or debugger services were added. **M2 implementation is COMPLETE for the bounded preview.** The bounded M3 baseline has historical validation; automatic startup is implemented with [separate accepted validation](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted); next is **M4 Git/review, not started**; their [native dialogs/pickers/tags](WORKBENCH_M3_LANGUAGE.md) are not a new docked Problems/Outline panel or inline hint/lens layout. See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md).

The subsequent [native visual-alignment pass](WORKBENCH_M2_VISUAL.md) adds compact headers/overflow menus, design palettes and per-group breadcrumbs. Its validation and screenshots are separate from the historical dock-increment evidence below.

## Controls

Default placement is **Explorer left** (222px default width), **Search bottom** (initially hidden). Existing saved dimensions remain honored. The activity rail opens/toggles the real panels and provides Reset layout and Focus editor. Open Folder / Workspace are available through the titlebar workspace menu and Explorer overflow.

| Shortcut | Action |
| --- | --- |
| Ctrl+B | Toggle Explorer dock |
| Ctrl+Shift+E | Show/focus Explorer |
| Ctrl+Shift+F | Show workspace text search |
| Ctrl+P | Quick Open picker |
| Ctrl+Alt+P | Open Recent Project |
| Ctrl+Shift+O | Open Buffers in this window |
| Ctrl+1 | Focus the active editor/excerpt |
| Ctrl+Shift+B | Hide active auxiliary panel |
| Ctrl+Alt+Left / Right / Down | Move active panel left / right / bottom |
| Ctrl+Alt+PageUp / PageDown | Grow / shrink active dock by 40 logical pixels |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous editor tab |
| Ctrl+Shift+P | Command palette |

All dock operations also have palette/menu commands. Dock headers provide **Panel options** for move/grow/shrink/reset and a directly accessible Hide control. Drag a native splitter to resize. Placement is command/button-driven, **not drag-and-drop panel placement**. If the desktop reserves a shortcut, use the palette or buttons.

When both panels occupy the same dock, their header tabs select the visible panel. Empty docks collapse. Move/hide/reset operations preserve editor groups, documents, excerpts, selections and edit history. Each editor group has an independently shrinkable viewport so long tab/excerpt content cannot push siblings outside the central allocation; overflowing content may scroll.

### Explorer file-operation controls

Explorer provides **New file…** in its compact toolbar; **New directory… / Rename… / Move… / Delete…** are in **Explorer actions and safety information**. All remain exposed through menu and **Explorer:** palette commands. Select the entry first; **every kind requires input/review, worker preparation and a separate explicit confirmation before writing**. Creates do not auto-open. Delete is permanent, file/empty-directory only, with no trash, undo or recursion. These are real bounded operations, not dock placeholders or drag-and-drop moves.

All affected open documents (clean or dirty, in any window) must be resolved and closed first. The apply barrier refuses opens/saves/session/workspace switches/New Window through callback delivery while unaffected buffers remain editable. Success rescans Explorer and invalidates Search for explicit Refresh, without changing desired dock layout. See [file-operation usage, process-wide refusal rules and safety limits](WORKBENCH_M2_OPERATIONS.md), including the conservative `WorkspaceBusy` rule for any unavailable root or lexical `..` root/manifest anywhere in the process.

## Compact windows and focus

If the workbench content area is narrower than **900 px** or shorter than **420 px**, only one auxiliary dock panel is displayed at a time. Desired visibility, placement and dimensions are retained; widening the window restores the wide layout. The transient Quick Open picker can overlay this arrangement.

Below **520px content width**, the active panel is presented at the bottom rather than squeezing a side strip; widening restores its desired side placement. This responsive presentation does not rewrite saved placement.

Desired side widths are bounded to **120–1200 px**; bottom height to **100–1000 px**. Effective allocations may be smaller to retain editor space. Resizing the window does not serialize its temporary clamped allocation as the desired size. These bounds are logical GTK pixels, not device pixels.

Explorer row refreshes park focus on a stable container before recycling rows, then restore list focus only while Explorer still owns it. Watcher/search completions cannot reopen hidden panels or take focus from typing. Registered workbench shortcuts are selectively captured before GTK focus navigation; ordinary typing and widget-local/IME handling retain normal propagation. Native tests cover Unicode keyboard input, **not full physical IME or screen-reader qualification**.

## Quick Open and Search

**Ctrl+P** presents the existing bounded, virtualized path search in an overlay without reducing the editor allocation. Escape cancels it and returns to the active editor/excerpt. Successful activation first completes the checked navigation, then dismisses the presentation; dismissal does not invalidate that activation prematurely.

**Quick Open and text Search share one query/result controller**, explained in their title tooltips. Switching modes replaces that query's results; two simultaneous search engines are not implemented. A visible Search dock shows a sharing notice while Quick Open borrows its content. Explicit close cancels outstanding search work; moving a panel does not.

The command palette remains its existing transient modal window. Open Folder / Workspace continue using the existing choosers. Native [Recent Projects and Open Buffers](WORKBENCH_M2_PROJECTS.md) now use separate modal snapshot pickers: at most 512 captured items and 50 displayed matches; refine the filter, with no unlimited history-addressability claim. Recent Projects activates a matching owner or restores an independent window. Worktree/symbol pickers, floating docks and cross-window tab dragging remain outside M2.

## Saved layout and migration

**Save Workspace Session** now records desired panel placement, visibility, active panel and all three sizes alongside its document/workspace checkpoint. **Restore Workspace Session** applies that layout only after successful document restoration. Invalid layout data is rejected before live workspace/document mutation. Layout contains no settings/trust permissions.

The session envelope is now **v2**. It requires a layout object; unknown fields/enums, invalid types and out-of-range dimensions fail closed. Existing **v1** checkpoints remain readable and restore the default dock layout. A subsequent explicit save upgrades the slot to v2. Older binaries refuse v2 rather than silently dropping its layout. Recovery journals remain unchanged and do not persist dock state.

The original explicit checkpoint remains shared and unchanged by automatic persistence. The separate [automatic project catalog](WORKBENCH_M2_PROJECTS.md) now captures desired layout with each per-window/project snapshot and restores eligible windows on ordinary startup. Retention is bounded and errors are visible; it is not every-keystroke durability or desktop window-position restoration. No repository setting grants restoration authority. See [explicit session safety and limits](WORKBENCH_M2_SESSIONS.md).

## Implementation

- `src/workbench/dock.zig`: GtkPaned hosts, activity rail, overlay picker, compact presentation, resizing and focus-safe reparenting.
- `src/workbench/layout.zig`: bounded pure layout state and validation.
- `src/app.zig`, `src/workbench/commands.zig`: commands, shortcuts, focus routing and editor-group containment.
- `src/workspace/controller.zig`, `search_controller.zig`, `search_view.zig`: explorer/search presentation and focus-safe refresh.
- `src/workspace/session_model.zig`, `session_controller.zig`: v2 layout serialization and successful-restore application.
- `src/workbench/dock_widget_test.zig`, `tests/docks.py`: widget and native geometry/focus acceptance.

## Validation

From `subprojects/coral`:

```sh
zig build docks -Doptimize=safe -j1
zig build test-m2-docks -Doptimize=safe -j1 --summary all
zig test src/session_tests.zig -lc
```

**Historical dock-increment final sequential safe gates all passed:** `test-m2-docks`, `test-m2-sessions`, `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search`, `test-m2-policy`, then the production build with `-Dtest-hooks=false`. Every command used `-j1`; native fixtures use private Wayland/HOME/XDG directories and disposable files.

- **27 native dock scenarios**, including real pointer drags on all three splitters, dock geometry, same-dock tabs, compact/wide transitions, editor-group containment, picker activation/cancellation, palette focus, hidden-worker behavior, edits/history, v2 roundtrip/v1 migration and invalid-layout retention.
- Keyboard regressions cover Ctrl+Tab/ISO_Left_Tab, ordinary Tab/Unicode input, undo/redo, Find Escape, focused Explorer row replacement and watcher focus ownership.
- **190 widget-root tests** passed in each applicable final gate. Headless runners were cached on the final aggregate rerun; focused session/layout validation executed **23 tests**, including the test root and transitive layout tests. Counts overlap and are not unique totals.
- Existing native gates passed **19 sessions, 40 workflows, 14 group/history, 13 recovery, 18 workspaces, 19 explorer, nine search and 17 policy groups**.

Initial broad validation caught a stale v1-only test fixture and real key/focus regressions. The fixture now constructs future versions independently of current schema. Selective shortcut capture, stable focus during row replacement and Find's stop-search handling fixed the regressions; their failing logs are retained beside the passing `final-*` logs.

Evidence: `pearl/.cache/coral-docks/results.json`, adjacent logs/screenshots, and `pearl/.cache/coral-dock-validation-logs/final-*.log`. Focused run evidence under `pearl/subprojects/coral/.cache/docks-focus-acceptance-agent-20261109/full/` includes 172 geometry observations and 18 screenshots; these are local functional checks, not paint-latency measurements.

[Multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) and [bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) are now implemented: each window owns its dock state, while Save/Restore Workspace Session still uses one shared explicit checkpoint. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The dock gate again passed 27 native scenarios and executed 191 widget tests, separate from the historical dock evidence above. [Automatic projects, recent/buffer pickers and reviewed root management](WORKBENCH_M2_PROJECTS.md) now complete mandatory M2 scope. The [acceptance report](WORKBENCH_M2_ACCEPTANCE.md) separates current validation from historical dock counts. These are historical M2 validation checkpoints, not current M3 acceptance. The bounded M3 baseline has historical validation; approved automatic-language startup is now implemented with [separate accepted validation](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted). **Next is M4 Git/review, not started**; production terminal/tasks and agents remain later milestones. No placeholder service docks were added.

The historical separate [M3 visual pass](../../../.cache/coral-m3-final-visual.log) passed **16/16 cases and four font-ratio checks before the final queue/sync-only change**, not on the final binary. A secondary-panel footer still ellipsizes/clips at **390px**; this is not no-clipping or full visual parity acceptance. The historical M3 aggregate, before the automatic-lifecycle increment, passed **204 widgets in 42.099s**, alongside the language and full M1/M2 regressions. See [final counts, logs and evidence boundaries](WORKBENCH_M3_LANGUAGE.md#final-validation-passed); harness reaping assertions passed, but no final baseline cleanup scan was done.
