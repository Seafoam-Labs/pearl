# Persist view and hidden-file preferences

Status: implemented · September 27, 2026.

Implemented in `src/platform/preferences.zig`, `src/tab.zig`, and
`src/window.zig`. The native suite now covers restart persistence, independent
tab/window state, defaults and invalid values, preservation of other preferences,
and save-failure recovery. The context-menu suite verifies that view and hidden
file actions save the same defaults. The original plan follows.

Phyto should remember the user's chosen icon/grid or detailed-list view and
whether hidden files are shown, including after the application exits.

## Behavior

Use the last explicit choice for each setting as an application-wide default.
New tabs and windows start with those defaults. Existing tabs retain their own
view and hidden-file state, consistent with Phyto's independent tab/pane model.
Changing one setting leaves the other saved setting untouched.

- First launch, missing keys, or invalid values: grid view and hidden files off.
- Toolbar buttons, keyboard shortcuts, More options, and background context-menu
  actions all update the same saved defaults when applicable.
- Save immediately after an explicit choice. Navigation, refresh, tab/pane
  switching, startup, and shutdown do not overwrite the saved defaults.
- Choosing a view already active in the current tab still updates the default
  if another tab last saved a different view.
- Newly created tabs, including the existing duplicate-tab action, use the saved
  defaults. Moving a tab between panes preserves its current state.
- Both initial pane tabs load the saved defaults. Phyto creates the second pane's
  tab at window construction; subsequently revealing that pane preserves its
  state, just like returning to any existing tab.
- Windows in the same process share the latest defaults through the existing
  preferences object. Cross-process live synchronization and per-folder settings
  are outside this change; separate processes retain the existing save behavior.

## Baseline before implementation

`src/platform/preferences.zig` already loads and saves a process-shared GLib
key file at `$XDG_CONFIG_HOME/phyto/preferences.ini` (normally
`~/.config/phyto/preferences.ini`). It persists sorting, previews, bookmarks,
and menu options, and writes through GIO `replaceContents`.

`src/tab.zig` currently initializes `list_mode` and `hidden` to false.
`Window.dispatch` in `src/window.zig` changes those fields without saving them.
Context-menu view actions route through that dispatcher. Preferences are acquired
before the window creates either pane's initial tab.

## Implementation steps

1. **Extend the existing preferences file.** Add a `ViewMode` enum (`grid`,
   `list`), a `view_mode` field defaulting to `grid`, and a `show_hidden` boolean
   defaulting to false in `src/platform/preferences.zig`. Load and save `mode`
   and `show-hidden` in the existing `[View]` group:

   ```ini
   [View]
   mode=list
   show-hidden=true
   ```

   Keep existing keys and groups. Validate each new value independently;
   unknown modes and invalid booleans fall back to their defaults. Older files
   need no migration and should not be rewritten merely because they were read.

2. **Restore state during tab construction.** Initialize `list_mode` and
   `hidden` from `owner.preferences` in `Tab.create`, and select the corresponding
   GTK stack child before the first navigation/enumeration. Avoid calling the
   existing `Tab.setView` during construction: it calls `owner.sync()` before
   the new tab has been inserted into its pane. Startup restoration must not
   save preferences or briefly display the wrong view/filter.

3. **Save explicit user changes in the dispatcher.** Extend the `.grid`, `.list`,
   and `.hidden` branches of `Window.dispatch` to update the appropriate shared
   preference and save it after applying the tab change. Keep `Tab.setView` a
   UI operation so programmatic restoration cannot accidentally persist state.
   Preserve filter invalidation, toolbar selection, and context-menu checkmarks.
   Avoid redundant writes when the saved value already matches; permit retry
   after an earlier save failure.

4. **Handle write failures visibly.** Retain the user's current tab state and
   in-memory default if saving fails. Check the existing `save_error` flag and
   show the existing “Preferences were not saved” message directly from this
   save path. Its current use in `refreshPlaces` will not reliably report a view
   change failure. A subsequent successful save should clear the failure flag.

5. **Add focused persistence coverage and documentation.** Extend the private
   native test harness and test-only state probe to expose `hidden` alongside
   the existing `list` field. Add a focused restart scenario using a disposable
   config directory, and update README behavior/configuration documentation.
   Review existing native tests that reuse a config directory across launches:
   seed/reset preferences for cases expecting first-launch defaults and retain
   the same config only for persistence cases.

## Verification and acceptance

- With no file or an older preferences file, launch in grid view with hidden
  files excluded. Invalid new values fall back independently without a crash.
- Exercise all four grid/list × hidden on/off combinations. After each choice,
  inspect the INI values, fully exit the process, relaunch with the same temporary
  config, and verify the actual view, hidden-file listing, and menu state.
- Exercise toolbar/shortcuts and context-menu changes; confirm new tabs/windows
  inherit the last choices and existing tabs/panes retain their own state.
- Switch back to a tab with different settings, navigate, refresh, reveal the
  pre-created split pane, and close windows in different orders. None of these
  actions should replace the last explicitly saved choices.
- Change only one preference and verify the other plus existing sorting,
  bookmarks, menu, and preview settings survive the save/reload.
- Force a write failure in the disposable configuration (for example, make the
  target preferences path a directory). Verify visible feedback, usable current
  state, and successful saving after the obstruction is removed.
- Run `zig build test`, `zig build integration -Doptimize=ReleaseSafe`, and
  `zig build test-context-menus -Doptimize=ReleaseSafe` from `subprojects/phyto`.
  All three checks passed after implementation: 15 unit tests, 13 native check
  groups, and 16 context-menu check groups. Native sessions used disposable
  configuration/data directories; results are in
  `/tmp/phyto-view-preferences-native/results.json` and
  `/tmp/phyto-view-preferences-menus/results.json` for this run.
