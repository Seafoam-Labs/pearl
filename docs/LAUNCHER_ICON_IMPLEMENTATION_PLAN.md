# Configurable app launcher icon

Status: implemented, 2026-09-20. Validation results are recorded in
[launcher icon evidence](../artifacts/launcher-icon/README.md). Output disable/enable
verification remains blocked by the pinned Aqueous compositor assertion described
there; the test retains an opt-in reproducer.

## Scope and intended behavior

“App launcher icon” means the bar's **Applications** button that
opens Pearl's app launcher. Individual application icons and desktop-entry
associations are a separate feature.

Users can open **Settings → Bar & dock → Launcher → Change icon…**, select a
bundled icon, enter an installed icon-theme name, or choose a local PNG. The
editor shows the selection in its draft preview. **Apply & save** updates the
live bar without restarting Pearl; **Discard** restores the saved selection.
**Reset to default** restores the current Applications icon.

The button keeps its Applications tooltip, accessible name, keyboard behavior,
click action, and existing allocation. Image aspect ratio is preserved within
the normal icon bounds. Symbolic theme icons follow the active palette; custom
PNG images retain their colors and transparency.

## Existing implementation

- `src/desktop/bar.zig` hard-codes
  `pearl-application-x-executable-symbolic` for the launcher button.
- `src/settings/bar_model.zig` uses `pearl-view-grid-symbolic` for the Launcher
  metadata; `bar_view.zig` uses that metadata in its schematic preview.
- `src/config/preferences.zig` defines `Bar`, validates both default and
  per-output bars, and resolves them through `Preferences.forOutput()`.
  An output's `bar` is a complete replacement, not a field-by-field overlay.
- `src/ui/surfaces/manager.zig` applies committed preferences to each output's
  bar and rebuilds its groups when the preference revision changes.
- `src/settings/bar_view.zig` already provides widget action popovers and edits
  the shared draft. The default bar is edited here; output overrides are in
  Advanced. `config/merge.zig` handles conflicts, treating output arrays atomically.
- `src/settings/preferences_view.zig` has a native wallpaper chooser pattern.
  `src/theme/assets.zig` provides bounded static PNG validation and normalization.

## Preference contract

Add `launcher_icon` to `Preferences.Bar`, backed by a small shared policy type in
`src/desktop/launcher_icon_policy.zig`:

```json
{
  "bar": {
    "launcher_icon": {
      "kind": "theme",
      "value": "pearl-view-grid-symbolic"
    }
  }
}
```

| Kind | Value | Behavior |
| --- | --- | --- |
| `default` | Empty string | Current bundled Applications icon |
| `theme` | Icon name | Resolve through GTK's icon theme, including bundled icons |
| `file` | Absolute local PNG path | Validate and render a bounded static image |

Omitted settings default to `{ "kind": "default", "value": "" }`. Keep schema
version 1, following existing additive preference changes. Validate the kind/value
pair: theme names are nonempty, at most 128 bytes, and limited to letters, digits,
dots, underscores and hyphens; file paths are nonempty absolute paths of at most
1024 bytes with valid UTF-8 and no control characters. Availability is checked by
the renderer, not by the preference parser, so a removed image cannot invalidate
the entire preferences document.

Preserve existing output replacement semantics. An output override with no icon
field uses the default icon, even when the default bar has a custom selection.
Explain this in Settings and document a complete per-output example. Introducing
field inheritance or a new output editor is outside this change.

Treat an icon selection as one logical value in three-way merging: simultaneous
different changes to its kind/value must conflict, rather than combining a path
from one edit with a kind from another. Preserve existing output-array conflicts.
Document that older strict parsers reject the new field on downgrade.

## Implementation and acceptance

### 1. Preference model and draft editing

Add the policy type, validation, default icon constant, and preference field.
Extend `bar_model.zig` with a validated icon patch helper that preserves all other
draft fields and output overrides. Update merge handling for atomic icon choices.

Completion: old preferences retain their appearance; all three selection kinds
round-trip; invalid input and conflicting edits leave the saved state intact.

### 2. Shared rendering and live application

Add `src/ui/components/launcher_icon.zig` as a shared resolver/renderer for the
bar and Settings preview. Resolve theme names with an explicit bundled fallback.
For PNGs, reuse the existing bounded validator (currently 2 MiB and dimensions
up to 2048 × 2048), passing only validated image data to GTK. Keep decoding off
the regular bar update path; cache results and discard obsolete asynchronous
loads when a newer selection replaces them or a view closes.

Store an owned selection on `Bar`, apply it from the surface manager on initial
creation and committed preference changes, and preserve it across group rebuilds,
orientation changes, and output hotplug. Use the same renderer in the editor's
Launcher row and draft preview, removing the current preview/runtime mismatch.

Missing theme names and missing, unreadable, or invalid PNGs show the default icon
and a readable Settings warning while retaining the selection for repair. Provide
a Retry action to reload the same path. Load on startup, selection changes, and
explicit retry; automatic file watching is outside the first implementation.

Completion: applying a selection updates the intended bars without restart,
including newly connected outputs; a failed load never hides the launcher button.

### 3. Native Settings controls

Add **Change icon…** to the Launcher widget's action popover. Present a small
labelled set of existing bundled icons, an **Icon theme name** field with preview,
and **Choose PNG…** using the existing native file chooser pattern. Include
**Reset to default**, a clear selected-source label, and actionable load errors.

Keep edits in the shared draft and follow the editor's stale-draft checks and
Apply/Discard behavior. A cancelled chooser makes no change. A rejected file
leaves the previous selection intact. Make the chooser owned by the Settings
window and ignore late callbacks after closure or a superseding draft revision.
Explain that a selected PNG must remain at its saved location; copying assets
into managed storage is outside this first implementation.

Completion: the entire flow works by keyboard, focus returns to the Launcher
control, and the accessible button name stays Applications regardless of artwork.

### 4. Verification and documentation

- Unit coverage: defaults, round trips, kind/value validation, output resolution,
  draft field preservation, disjoint merges, and conflicting icon selections.
- Extend `tests/integration/test_settings_bar_editor.py` for selection, preview,
  cancellation, reset, Apply/Discard, saved-state restoration, and stale callbacks.
- Extend bar integration coverage for live changes, restart, all four edges,
  multiple outputs, override behavior, hotplug, and unchanged launcher activation.
- Exercise missing theme icons; missing, corrupt, oversized and animated PNGs;
  retry; and rapid changes while an image is loading.
- Capture dark/light and GTK-theme evidence at normal and enlarged scale, with
  a nonsquare transparent PNG, minimum bar thickness, and keyboard focus visible.
- Update `docs/PREFERENCES.md`, `docs/DESKTOP.md`, and the bar-editor mockup to
  describe the controls, file lifetime, output semantics, fallback, and downgrade.

Run `zig build test`, `zig build test-settings-bar-editor`,
`zig build test-bar-layout`, and `zig build test-preferences` after implementation;
extend existing private-session fixtures rather than changing the user's session.

## Release acceptance

A user can choose and preview an icon, apply it without restarting, restart Pearl
without losing it, and reset it. The preview agrees with the live button. Missing
assets produce a usable fallback. Existing preferences and launcher interactions
retain their behavior, and per-output results match the documented replacement
rules. Arbitrary SVG files, animation, asset importing, and individual application
icon overrides remain separate follow-up work.

## Delivery notes

- The native **Change icon…** button opens a dedicated popover. Before presenting
  the file chooser, it closes the popover to release its input grab. Cancellation
  restores focus to Launcher; a changed draft cancels the pending chooser/load.
- The renderer owns selection strings, cached pixels and GTK target references.
  GIO workers own their paths/cancellables and detach from cancelled or destroyed
  owners. Unrelated preference changes reuse the loaded PNG.
- Retry has a capability-gated `launcher-icon.retry` Settings operation. It only
  reloads bars whose saved selection matches the requested selection and never
  applies a draft. The Settings preview reloads independently.
- PNG validation reuses the existing static-image bounds and canonicalization.
  Regular local files are supported; symlink paths are rejected by the existing
  bounded file reader. Choose the actual file when a shortcut path fails.
- The enlarged editor integration suite restarts its private shell between icon
  cases and pre-existing editor cases to respect the bounded operation ledger.
