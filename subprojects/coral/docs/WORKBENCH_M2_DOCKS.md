# M2: native docks and picker integration

**Implemented:** Explorer and workspace Search now live in movable, resizable, hideable native docks around the central editor. Quick Open uses a transient in-window picker. This is a functional workbench-layout increment, not pixel-for-pixel mockup parity or a complete IDE. No placeholder Git, agent, terminal or debugger services were added.

## Controls

Default placement is **Explorer left**, **Search bottom** (initially hidden). The activity rail opens/toggles the real panels and provides Reset layout and Focus editor. Empty Explorer offers Open Folder / Workspace actions.

| Shortcut | Action |
| --- | --- |
| Ctrl+B | Toggle Explorer dock |
| Ctrl+Shift+E | Show/focus Explorer |
| Ctrl+Shift+F | Show workspace text search |
| Ctrl+P | Quick Open picker |
| Ctrl+1 | Focus the active editor/excerpt |
| Ctrl+Shift+B | Hide active auxiliary panel |
| Ctrl+Alt+Left / Right / Down | Move active panel left / right / bottom |
| Ctrl+Alt+PageUp / PageDown | Grow / shrink active dock by 40 logical pixels |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous editor tab |
| Ctrl+Shift+P | Command palette |

All dock operations also have palette/menu commands. Dock headers provide move, grow/shrink and hide controls. Drag a native splitter to resize. Placement is command/button-driven, **not drag-and-drop panel placement**. If the desktop reserves a shortcut, use the palette or buttons.

When both panels occupy the same dock, their header tabs select the visible panel. Empty docks collapse. Move/hide/reset operations preserve editor groups, documents, excerpts, selections and edit history. Each editor group has an independently shrinkable viewport so long tab/excerpt content cannot push siblings outside the central allocation; overflowing content may scroll.

## Compact windows and focus

If the workbench content area is narrower than **900 px** or shorter than **420 px**, only one auxiliary dock panel is displayed at a time. Desired visibility, placement and dimensions are retained; widening the window restores the wide layout. The transient Quick Open picker can overlay this arrangement.

Desired side widths are bounded to **120–1200 px**; bottom height to **100–1000 px**. Effective allocations may be smaller to retain editor space. Resizing the window does not serialize its temporary clamped allocation as the desired size. These bounds are logical GTK pixels, not device pixels.

Explorer row refreshes park focus on a stable container before recycling rows, then restore list focus only while Explorer still owns it. Watcher/search completions cannot reopen hidden panels or take focus from typing. Registered workbench shortcuts are selectively captured before GTK focus navigation; ordinary typing and widget-local/IME handling retain normal propagation. Native tests cover Unicode keyboard input, **not full physical IME or screen-reader qualification**.

## Quick Open and Search

**Ctrl+P** presents the existing bounded, virtualized path search in an overlay without reducing the editor allocation. Escape cancels it and returns to the active editor/excerpt. Successful activation first completes the checked navigation, then dismisses the presentation; dismissal does not invalidate that activation prematurely.

**Quick Open and text Search share one query/result controller**, explicitly labelled in both presentations. Switching modes replaces that query's results; two simultaneous search engines are not implemented. A visible Search dock shows a sharing notice while Quick Open borrows its content. Explicit close cancels outstanding search work; moving a panel does not.

The command palette remains its existing transient modal window. Open Folder / Workspace continue using the existing choosers. Recent-workspace/worktree/symbol pickers, floating docks and cross-window tab dragging remain future work.

## Saved layout and migration

**Save Workspace Session** now records desired panel placement, visibility, active panel and all three sizes alongside its document/workspace checkpoint. **Restore Workspace Session** applies that layout only after successful document restoration. Invalid layout data is rejected before live workspace/document mutation. Layout contains no settings/trust permissions.

The session envelope is now **v2**. It requires a layout object; unknown fields/enums, invalid types and out-of-range dimensions fail closed. Existing **v1** checkpoints remain readable and restore the default dock layout. A subsequent explicit save upgrades the slot to v2. Older binaries refuse v2 rather than silently dropping its layout. Recovery journals remain unchanged and do not persist dock state.

Persistence is still **one explicit shared checkpoint**, not automatic layout autosave, a per-project layout registry, or automatic startup resume. Unsaved dock changes are not restored after exit. No new preference file or repository setting was introduced. See [session safety and limits](WORKBENCH_M2_SESSIONS.md).

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

**Final sequential safe gates all passed:** `test-m2-docks`, `test-m2-sessions`, `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search`, `test-m2-policy`, then the production build with `-Dtest-hooks=false`. Every command used `-j1`; native fixtures use private Wayland/HOME/XDG directories and disposable files.

- **27 native dock scenarios**, including real pointer drags on all three splitters, dock geometry, same-dock tabs, compact/wide transitions, editor-group containment, picker activation/cancellation, palette focus, hidden-worker behavior, edits/history, v2 roundtrip/v1 migration and invalid-layout retention.
- Keyboard regressions cover Ctrl+Tab/ISO_Left_Tab, ordinary Tab/Unicode input, undo/redo, Find Escape, focused Explorer row replacement and watcher focus ownership.
- **190 widget-root tests** passed in each applicable final gate. Headless runners were cached on the final aggregate rerun; focused session/layout validation executed **23 tests**, including the test root and transitive layout tests. Counts overlap and are not unique totals.
- Existing native gates passed **19 sessions, 40 workflows, 14 group/history, 13 recovery, 18 workspaces, 19 explorer, nine search and 17 policy groups**.

Initial broad validation caught a stale v1-only test fixture and real key/focus regressions. The fixture now constructs future versions independently of current schema. Selective shortcut capture, stable focus during row replacement and Find's stop-search handling fixed the regressions; their failing logs are retained beside the passing `final-*` logs.

Evidence: `pearl/.cache/coral-docks/results.json`, adjacent logs/screenshots, and `pearl/.cache/coral-dock-validation-logs/final-*.log`. Focused run evidence under `pearl/subprojects/coral/.cache/docks-focus-acceptance-agent-20261109/full/` includes 172 geometry observations and 18 screenshots; these are local functional checks, not paint-latency measurements.

[Multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) is now implemented: each window owns its dock state, while Save/Restore Workspace Session still uses one shared explicit checkpoint. **Next standard M2 increment:** separately authorized workspace create/rename/move/delete with dirty-buffer and containment safeguards. Automatic/per-project session management remains open. LSP, Git, terminal/tasks and agents remain later milestones.
