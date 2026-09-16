# Aqueous settings sublist navigation

Status: implemented September 16, 2026; validation evidence is recorded in
[the implementation review](../artifacts/aqueous-navigation/README.md).

## Goal

Make Aqueous navigation behave like the rest of Pearl Settings. Replace the
section dropdown in the page header with an indented sublist beneath Aqueous in
the existing navigation. Keep the same page layout, selection treatment,
keyboard interaction, and draft-preserving navigation used by the application.

This updates the second-level selector described in the
[standalone application plan](STANDALONE_SETTINGS_APPLICATION_PLAN.md).

## Implemented interaction

The System navigation group becomes:

```text
Session & lock
Aqueous
    Appearance
    Layouts
    Input
    Shortcuts
    Rules
    Displays
    Advanced
Advanced
```

- Selecting Aqueous reveals its children and opens the last visited Aqueous
  section in this window, defaulting to Appearance on first entry. Selecting
  Aqueous again retains the current section.
- Show the sublist while Aqueous is the current top-level page. Hide it when
  navigating to another top-level page, retaining the last section. A separate
  expand/collapse control is unnecessary for this initial change.
- Child rows select their section directly. Use the existing navigation row
  shape, typography, focus outline, and theme colors, with modest indentation
  and at least 44-pixel interaction targets.
- Give the active child the selected-row highlight. Identify Aqueous as its
  parent without a second selected-row highlight. Distinguish keyboard focus
  from selection and distinguish child Appearance/Advanced from Pearl's pages.
- Show a small Aqueous context label above the selected section's page title,
  for example Aqueous / Displays. Remove the section dropdown. Keep the current
  fixed header, body viewport, and shared Aqueous action footer.
- In narrow windows, put this same hierarchy in the existing **Sections**
  popover. Entering Aqueous from another page reveals its children and keeps
  the popover open; choosing a child closes it. Escape closes the popover and
  returns focus to Sections. Resize preserves the selected section.
- Keep all children reachable by scrolling the navigation in short windows.
  Use the application's existing keyboard activation conventions; do not
  introduce a separate custom tree keyboard model.
- Internal navigation restores each section's scroll position and valid last
  focused control. First visits start at the section heading. Explicit external
  links select their section and start at its heading.
- Preserve current external behavior: an Aqueous launch without a section
  opens Appearance. Remembering the last section is window-local, not a new
  persisted preference.

## Starting implementation and implications

- `src/settings/window.zig` builds two copies of the same top-level navigation:
  the sidebar and narrow Sections popover. Its separate `section_chooser`
  dropdown owns Aqueous section switching through `sectionChanged`.
- Top-level links use `requestSelect`, including pending Aqueous draft transfer,
  then the editor's navigation flow. The dropdown flushes and switches directly.
  Child links should use the common navigation flow instead.
- `src/desktop/settings_navigation.zig` already defines `Target { page, section }`
  and the stable IDs `appearance`, `layouts`, `input`, `keybinds`, `rules`,
  `displays`, and `advanced`. The displayed Shortcuts label maps to `keybinds`.
- `src/desktop/aqueous_settings.zig` already hides notebook tabs in the standalone
  application and exposes `showPage`. Retain that content host; replacing the
  notebook is not required for this navigation change.
- The window currently stores focus by top-level route and uses one Aqueous
  viewport. Section-specific restoration needs explicit state, including safe
  invalidation when the editor rebuilds its controls.

## Implementation sequence

### 1. Represent navigation destinations consistently

- Extend the window's navigation links to carry a complete `nav.Target` rather
  than only a top-level route. Retain stable callback storage for both copies
  of the navigation and existing Overview links.
- Keep section IDs and order in the existing shared registry. Centralize their
  translated display labels in the frontend for child rows and headings.
- Resolve the effective Aqueous section before selection so the target, editor,
  visible page, heading, and both navigation copies agree.

### 2. Build the sublist in both navigation surfaces

- Insert the seven child rows immediately below Aqueous in `Window.navigation`.
  Reuse the same builder for the sidebar and Sections popover.
- Remove `section_chooser`, its header widget, signal connection, and callback.
- Route child activation through `requestSelect` with `.page = .aqueous` and
  the stable section ID. Preserve pending draft transfer and failure handling.
  Change the visible selection only when navigation is accepted.
- Synchronize parent context, child selection, visibility, and section heading
  for clicks, keyboard activation, Overview links, and external activation.
- Handle popover dismissal explicitly so entering the Aqueous group can reveal
  its children without closing the navigation.
- Add only the necessary indentation and parent-context styling in
  `resources/settings-layout.css`, using `resources/settings.css` if an
  additional themed state is needed. Preserve native GTK and Material styling.

### 3. Preserve section state and editor lifecycle

- Store scroll/focus state per Aqueous section while retaining the shared
  viewport. Capture the departing section before changing notebook pages;
  restore the arriving section after GTK completes layout.
- Coordinate `showPage` with the window's focus restoration so its current
  automatic focus movement cannot override heading or saved-control focus.
- Invalidate stored widget references before form rebuild/destruction. Restore
  a surviving control where possible, otherwise fall back to the heading;
  clamp saved scroll positions to the current content range.
- Preserve selected section through refresh, rebase, delayed initial loading,
  backend recovery, and wide/narrow layout transitions.
- Retain shortcut-recording cancellation on navigation and display-preview
  Keep/Revert access. Section switches must neither save nor discard a draft.
- Keep the existing separate Pearl and Aqueous draft/action semantics and all
  CLI section IDs. Scope presentation changes to the standalone application;
  the shared editor's compact host must continue to work.

### 4. Validate behavior and presentation

Extend existing standalone tests rather than the similarly named compact
flyout navigation suite:

- `tests/integration/test_settings_app.py`: real pointer and keyboard selection
  of all seven child rows, parent reentry, selected-state synchronization,
  heading context, explicit CLI section links, invalid-target rejection, narrow
  popover expansion/dismissal, and resize retention.
- `tests/integration/test_settings_services.py`: edit a field, switch child
  sections while transfer is pending, leave Aqueous, and return; verify draft
  retention, per-section scroll/focus, rebuild safety, and continued access to
  validation, save, recording, recovery, and display-preview operations.
- `tests/integration/test_settings_presentation.py`: capture the expanded
  hierarchy and representative section bodies in wide, narrow, and short
  windows, dark/light/native GTK themes, larger text, and supported scaling.
  Update selection assertions to account for parent context and selected child.
- Extend test-only navigation reporting as needed to expose section targets,
  child bounds, and selected state. Use actual UI activation to test the new
  rows rather than relying solely on programmatic page selection.
- Check accessible child names include Aqueous context, active selection is
  announced, hidden children are absent from focus traversal, and keyboard
  users can reach the final top-level Advanced row after the expanded group.

Run the pure test suite and `zig build test-settings-app`,
`zig build test-settings-services`, `zig build test-settings-presentation`, and
`zig build test-settings-integration`. Run the shared Aqueous editor regression
`zig build test-aqueous-settings` if its focus/page-switch implementation changes.
Record any environment-blocked or manual checks separately from passing tests.

## Completion criteria

- There is no Aqueous section dropdown in the standalone app.
- All seven sections are accessible from an indented sublist in both wide and
  narrow navigation, with one clearly selected destination.
- Parent, child, heading, editor, and external navigation remain synchronized.
- Returning to a section restores its position without losing draft edits or
  focusing stale/hidden controls.
- Existing fields, CLI links, draft operations, and display-preview controls
  remain available; navigation performs no implicit save or discard.
- Update `docs/AQUEOUS_SETTINGS.md` and the standalone application plan to
  describe the delivered behavior, and retain screenshots and test results for
  review. No backend protocol or compositor capability changes are required.
