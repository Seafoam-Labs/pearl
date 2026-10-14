# Desktop icons implementation plan

Status: implemented. Automated acceptance and remaining manual validation are
recorded in [desktop icon evidence](../artifacts/desktop-icons/README.md).

## Implementation notes

The six Zig modules described below now provide the shared asynchronous directory
store, bounded visible-cell rendering, selection, manual placement, file actions
and content-bound launcher approval. The wallpaper overlay, Appearance draft
controls and `pearlctl desktop focus` are integrated. New installs seed enabled
icons; existing documents retain the compatibility default, and missing or corrupt
main preferences recover the saved choice from last-known-good preferences.

File actions use small GIO worker wrappers in `actions.zig`; extracting Phyto's
operation and undo infrastructure would broaden this feature unnecessarily.
Phyto is unchanged. Rendering materializes only the visible rows and a small
overscan, rather than retaining one GTK widget per file. The existing Aqueous
on-demand focus contract supports the explicit focus command without a compositor
change. Settings exposes the five desktop preferences; folder actions and Retry
are in the desktop context menu.

The following sections retain the design and release acceptance checklist.
Unverified hardware, accessibility and failure-injection cases are not implied
to pass by the automated acceptance results.

Add a desktop icon grid for files, folders and application shortcuts, enabled
by default for new installations and configurable in Appearance settings.
Users can open items, select and arrange them, and manage basic desktop files
without opening a file manager. All implementation and build changes use Zig;
Python is limited to integration tests using Pearl's private-session harnesses.

## Scope and defaults

- Enabled by default for new installations through `Preferences.firstInstall()`.
  Existing preference documents without this setting retain disabled icons;
  explicit enabled/disabled choices survive upgrades and recovery.
- Read the user's configured XDG Desktop directory, including localized paths;
  do not assume `~/Desktop`, evaluate configuration as shell code, or silently
  display the home directory when desktop-directory support is disabled.
- Show ordinary files, folders, symlinks and supported `.desktop` launchers.
  Hide hidden files by default. Resolve ordinary icons through GIO and GTK's
  icon theme, with bundled fallbacks for missing icons and broken links.
- Single click selects; double click or Enter opens. Ctrl toggles selection,
  Shift extends it in grid order, and dragging empty space selects a rectangle.
  Arrow keys move focus, Space selects, Ctrl+A selects all, and Escape cancels
  an active gesture or clears selection. Labels wrap to two lines; tooltips and
  accessible names retain the full display name.
- Start with name sorting, folders first, 48-logical-pixel icons and a grid that
  accounts for text size. Support automatic arrangement and manual snap-to-grid
  placement. Changing icon size must not lose saved manual positions.
- Initially show the desktop on one chosen display. An empty display preference
  chooses the first connected connector in stable lexical order. A disconnected
  chosen display falls back by the same rule; reconnection restores it. The same
  files appear across workspaces, with no duplicate grid on other displays.
- Include Open, Open containing folder, Rename, Move to Trash and New folder.
  Provide Add application shortcut from the installed app catalog, plus Arrange
  by name and Desktop settings on the empty-space menu.
- Defer cross-display placement, external drag-and-drop transfers, clipboard
  copy/move, permanent deletion, special Home/Trash/volume icons, thumbnails,
  arbitrary custom directories and per-workspace desktops. Opening the desktop
  directory in the default file manager covers advanced file operations.

The first usable milestone is a live grid with safe activation. Selection,
placement, basic file operations and Settings complete the initial release.

## Visual mockups

The [desktop and Settings mockups](mockups/desktop-icons/README.md) show the
proposed grid, selected folder, empty-space context menu and Appearance controls.
They are static design artifacts; sample files are illustrative, not files to
create on a new installation.

## Existing integration points

| Area | Current implementation and intended use |
| --- | --- |
| Output ownership | `src/ui/surfaces/manager.zig` owns wallpaper, bars, docks, output reconciliation and popup dismissal. Attach desktop views to this lifecycle. |
| Wallpaper | Wallpaper uses a background layer and a two-picture stack for transitions. Its input region is normally empty and becomes full for popup dismissal. Preserve transitions and explicitly revise input policy. |
| Background clicks | `wallpaperPressed` handles double-click cropping. Route icon gestures separately and retain cropping only for an unconsumed empty-background double click. |
| App discovery and launch | `src/desktop/apps.zig` supplies the shared monitored catalog; `launcher.zig` revalidates desktop IDs and uses a GDK launch context. Extract reusable activation logic where needed. |
| Preferences | `src/config/preferences.zig`, `service.zig`, `draft.zig` and `merge.zig` provide validation, committed changes and Settings conflict handling. |
| Settings | `src/settings/preferences_view.zig` and `preference_pages.zig` provide appearance controls; add a Desktop icons section using the existing draft lifecycle. |
| File operations | Phyto's `subprojects/phyto/src/operations/engine.zig` is a worker-only GIO engine, while its application UI is separate. Extract only the reusable operations required here into a shared Zig module. |
| Tests | `docs/TESTING.md` describes private HOME/XDG roots, buses and compositor sessions. Existing surface, desktop and preference suites provide regression coverage. |

Source code is authoritative where older surface documentation describes an
earlier milestone's focus behavior.

## Surface and input design

Prefer a `GtkOverlay` within the existing wallpaper window, with the current
wallpaper stack underneath a separate desktop view. This gives deterministic
wallpaper/icon ordering without relying on ordering between two background
layer surfaces. Icon widgets must remain outside the transitioning stack so a
wallpaper change never animates icons or discards selection.

The desktop reserves no additional application work area. Position cells within
the output's usable rectangle, converted to surface-local logical coordinates.
Avoid double-counting bar/frame reservations. Leave a stable clearance for dock
and autohide reveal areas so revealing them does not reposition icons. Keep
icons below normal and fullscreen application windows and existing shell UI.

Centralize wallpaper input decisions rather than allowing
`syncPopupDismissRegions` to overwrite the icon policy:

| State | Input and focus behavior |
| --- | --- |
| Icons disabled | Existing wallpaper pass-through and popup-dismissal policy. |
| Icons enabled on the selected output | Background accepts pointer input for icons, selection and menus. Keyboard mode is on-demand, never exclusive; mapping or refreshing does not take focus. |
| Principal popup open | Desktop activation and selection are suspended. When outside dismissal is enabled, consume the dismissing press before any desktop action. |
| Locked, inactive or disconnected session | Revoke desktop interaction, cancel gestures and menus, and prevent new launches or file operations through the existing lifecycle gates. |
| Output removed or feature disabled | Destroy the view and release its focus, callbacks and input regions; select a valid fallback output if enabled. |

Coordinate desktop context menus with existing popup ownership so they close
when another shell surface opens. A context menu must remain above application
windows even though its parent desktop is on the background layer; validate
GTK popup behavior in the initial surface spike. Escape and application
activation release menu ownership.

Add `pearlctl desktop focus [--output ID]` as a proposed keyboard entry point,
usable from a compositor binding. Reject disabled or non-host outputs before
changing focus. Verify whether Aqueous permits explicit background-surface
focus; if an additional compositor contract is necessary, document it before
committing to this command. Do not emulate desktop focus with an invisible
exclusive keyboard overlay.

## Model and asynchronous work

Create a small `src/desktop/icons/` package with these responsibilities:

- `model.zig`: item identities, sorting, selection and model reconciliation.
- `directory.zig`: Desktop-directory resolution, batched enumeration, GIO
  monitoring, cancellation and item metadata.
- `layout.zig`: pure grid geometry, hit testing, collision resolution and
  placement recovery.
- `view.zig`: GTK cells, accessibility, gestures and menus.
- `actions.zig`: validated activation and basic operation dispatch.
- `state.zig`: versioned placement persistence and recovery.

Use one directory model shared across view reconstruction, not one watcher per
widget. Keep filesystem enumeration and file operations off the GTK main
thread. Publish immutable owned snapshots with generation checks; cancelled or
late callbacks cannot mutate a replacement model or destroyed view. Debounce
watch bursts and reconcile changes without resetting unaffected selection.

Use child URIs as persistent keys, preserving the underlying filename bytes
separately from sanitized display labels. Migrate a placement on a reliable
rename event; use file identity only when available and unambiguous. A missing
identity must not cause two items to share placement or launcher approval.
Monitor Desktop-directory configuration changes and parent-directory changes
so removal, recreation and relocation recover without restarting Pearl.

A missing or unreadable directory yields an actionable state with Retry; no
automatic creation or home-directory listing. Offer explicit creation only for
a configured missing Desktop path. Bound metadata batches and icon loads, reuse
widgets for large directories, and provide scrollable overflow with keyboard
reachability rather than silently truncating files.

## Activation and file operations

Open regular documents and folders through GIO's default handlers and use the
existing GDK launch-context pattern. Revalidate the selected item at action
time. Never construct a shell command from a filename, URI or desktop entry.
Treat executable files as documents unless an explicit supported launcher flow
authorizes execution.

Application shortcuts created from the installed catalog copy a freshly
validated entry into the Desktop directory with a collision-safe name. Record
explicit approval for that exact content. Existing or externally copied
`.desktop` files require an Allow launching action that displays the application
and command first. Bind approval to the file location and content digest;
replacement or command changes invalidate it. Do not infer approval from an
executable bit alone, and do not follow launcher symlinks for approval. Launch
only supported Application entries through GIO's desktop-entry implementation;
keep malformed or unsupported entries visible with an explanation. Recheck
identity and content before dispatch and test replacement races.

Basic operations must have owned operands, cancellation, stale-target checks
and visible errors. Rename and folder creation must never overwrite a collision.
Move to Trash must not fall back to permanent deletion. Report partial success
for multi-item operations and refresh from the directory monitor afterward.
Selection and position changes do not move files on disk.

Extract the relevant Phyto worker code into a shared module under `src/files/`
with explicit build wiring for both applications; keep GTK window ownership and
undo UI out of that module. Preserve Phyto behavior and run its affected tests.
If extraction proves broader than the required operations, use small GIO async
wrappers first and document the boundary instead of importing Phyto's window.

## Preferences and placement state

Proposed additive `desktop_icons` preference for a new installation:

```json
{
  "desktop_icons": {
    "enabled": true,
    "output": "",
    "icon_size": 48,
    "show_hidden": false,
    "arrangement": "automatic"
  }
}
```

Validate icon sizes as 32, 48, 64 or 96 logical pixels and arrangement as
`automatic` or `manual`. Retain a saved disconnected output rather than rejecting
the preferences document. Keep the parsed model's omitted `enabled` default
`false` for compatibility with existing documents, and set it to `true` only in
`Preferences.firstInstall()`. Reuse the service's existing first-install gate:
initial shell startup, no requested document, no recovery, and both preferences
and last-known-good files missing. Persist the generated enabled choice through
the existing first-install commit. An existing empty document, an upgrade, a
parse error or restoration from last-known-good must not enable icons. Explicit
`false` always wins. A disabled or unavailable XDG Desktop directory still uses
the directory states above; enabled icons never imply displaying home contents.
Follow the current additive schema convention and document older strict-parser
downgrade behavior.
Keep these settings independent of the existing per-output bar replacement
semantics. Apply/Discard, stale drafts and concurrent settings edits use the
normal preference service; live directory and placement updates cannot dirty a
Settings draft.

Store placement separately at
`$XDG_STATE_HOME/pearl/desktop-icons.json`, using the standard state-home fallback.
Version the state, namespace positions by Desktop-directory URI, and store each
item's preferred row and column. The process owning the desktop is the sole
writer. Write atomically with debouncing and flush on orderly shutdown.

Distinguish preferred placement from temporary displayed placement. Scale,
rotation, font changes and fallback displays clamp or reflow displayed cells
without destroying preferred coordinates; returning to the original geometry
restores them. Resolve collisions deterministically and place new files in the
first available cell. Preserve manual placements while automatic mode is active.
Corrupt state falls back to automatic placement with a warning and retains the
bad file for recovery. Keep launcher approvals separate from layout recovery.

## Delivery milestones

1. **Surface and focus prototype.** Add an opt-in fixture grid over wallpaper.
   Verify stacking, popup dismissal, crop-click separation, background keyboard
   focus, context menus, fullscreen, lock and output removal in private Aqueous.
   Gate the remaining UI work on these results.
2. **Live directory and safe activation.** Implement the model, watching,
   cancellation, themed icons, launch-context reuse and launcher approval flow.
   Completion: live create/rename/delete events update the grid, files and
   folders open correctly, and an unapproved launcher cannot execute.
3. **Selection and layout.** Add keyboard/mouse selection, rubber-band selection,
   internal drag placement, overflow, output fallback and atomic state writes.
   Completion: every item is reachable and manual placement survives restart,
   display changes and wallpaper transitions.
4. **Basic actions and Settings.** Add folder creation, rename, trash, application
   shortcut creation, first-install defaults and the Appearance controls.
   Completion: new installations show icons without an opt-in step; existing
   users keep their saved behavior; Apply/Discard works live; failed actions
   leave accurate state and actionable feedback.
5. **Release validation and documentation.** Finish accessibility and lifecycle
   checks, register the new test suite, and document behavior and limitations in
   `docs/DESKTOP.md`, `docs/SURFACES.md` and `docs/PREFERENCES.md`.

## Verification and release acceptance

Use Zig unit tests for selection, ordering, grid bounds, collision handling,
preference defaults/validation/merging, placement recovery, launcher approval
invalidation and generation rejection. Integrations must use private Desktop
directories and a fixture launcher that records activation instead of starting
real user applications.

Test first installation with both preference files absent, existing `{}`,
explicit enabled/disabled values, missing main preferences with an existing
last-known-good file, corrupt preferences and a restart after disabling icons.
Only the first-install case seeds `enabled: true`; recovery and upgrades retain
their existing choice or compatibility default.

Add `tests/integration/test_desktop_icons.py` and a proposed
`zig build test-desktop-icons` target, registered with `scripts/test.py`.
Cover localized/unset/home-valued Desktop paths, missing or read-only folders,
Unicode and unusual filenames, hidden files, symlinks, malformed launchers,
launch failures, permission failures, rename collisions and concurrent changes.
Exercise watcher bursts and a 10,000-item directory; record responsiveness,
memory use and widget counts to confirm that rendering remains bounded.

Run the existing `zig build test`, `test-surfaces`, `test-desktop` and
`test-preferences` checks, plus affected Phyto tests if shared code changes.
Capture light/dark/native-theme and enlarged-text evidence, fractional scaling,
portrait displays, all bar edges, dock/autohide overlap, multiple outputs,
unplug/replug, session lock/unlock and repeated enable/disable cycles. Verify
keyboard-only access and accessible names, selection and focus announcements.

Release when a new installation presents the correct Desktop directory without
manual enablement, existing installations preserve their choice,
all items remain reachable, approved actions work without restarting Pearl,
manual positions survive restart, and disabling restores existing surface/input
behavior. No display change, stale callback or popup-dismissal click may launch
an item, lose files, or leave desktop focus captured.
