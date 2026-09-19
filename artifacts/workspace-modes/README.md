# Workspace display modes

Implemented from the [approved plan](../../docs/WORKSPACE_WIDGET_MODES_PLAN.md).
Open **Settings → Bar & dock → Workspaces → ⋯ → Display mode**, select a mode,
then **Apply & save**.

| Mode | Behavior | Native capture |
| --- | --- | --- |
| Small | Active + one neighbor on each side | [Live bar](layout/session/workspace-small-top.png) |
| Medium | Active + two neighbors on each side | [Live bar](layout/session/workspace-medium-top.png) |
| Large | All workspaces on the display; default | [Live bar](layout/session/workspace-large-top.png) |

Ranges stop at each end without wrapping. Neighbors use the existing sorted
workspace list, including gaps in workspace numbers. Each display follows its
own active workspace. Missing active state temporarily shows all workspaces.
Removing and re-adding the widget retains its mode.

The Settings selection updates the shared draft and illustrative preview. The
live bar changes on Apply; Discard restores the saved setting. Display overrides
remain in Advanced and retain the existing complete-override semantics.

| Settings view | Capture |
| --- | --- |
| Small selected | [Menu and draft preview](settings/session/workspace-mode-small.png) |
| Medium selected | [Menu and draft preview](settings/session/workspace-mode-medium.png) |
| Large selected | [Menu and draft preview](settings/session/workspace-mode-large.png) |
| Narrow window with larger text | [Light theme menu](settings/session/workspace-menu-light-20-560.png) |
| Narrowest tested window | [390 px window](settings/session/workspace-menu-light-14-390.png) |
| Saved mode after shell restart | [Scaled display](layout/session/workspace-medium-restarted-scaled.png) |

## Validation

| Check | Result |
| --- | --- |
| ReleaseSafe build | 31/31 steps passed · [log](build.log) |
| Pure unit suite | 149/149 passed · [log](unit.log) |
| Native Settings editor | 14 checks passed · [report](settings/metadata.json), [log](settings.log) |
| Native bar layout | 34 cases passed · [report](layout/metadata.json), [log](layout.log) |
| Preferences regression | 24 checks passed · [report](preferences/metadata.json), [log](preferences.log) |
| Running applications regression | 16 checks passed · [report](running-apps/metadata.json), [log](running-apps.log) |

Coverage includes clipped ranges, sparse workspace numbers, empty/unknown active
state, strict preference parsing and defaults, complete display overrides,
preserving unrelated draft fields, mode retention after removing the widget,
radio selected state, pointer and keyboard input, draft preview, Apply/Discard,
reopening Settings, stale-menu rejection, all four bar edges, external workspace
activation, exact IDs on filtered-button clicks, independent displays, larger
text, narrow windows, mixed scale, and shell-restart persistence. The taskbar
check verifies Small frees slots without changing the global application groups.

Native runs use private Aqueous sessions with fatal GTK warnings. Empty/missing
active state and sparse-number behavior are covered by pure policy tests; the
native fixture supplies fixed workspace lists. Screenshots show actual GTK
surfaces, not design mockups.

Reproduce with the build/test commands in the approved plan. Private integration
sessions require permission to create local Wayland and D-Bus sockets.
