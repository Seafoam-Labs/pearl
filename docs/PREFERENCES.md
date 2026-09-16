# Preferences, wallpaper and themes

[T15 dock and island layouts](DOCK_ISLANDS.md) add persistent app pins, per-output
dock behavior, split bar sections and matching native input/blur regions.

Open **Pearl Settings** from the launcher or use
`pearlctl settings show --page appearance`. The compact preference editor remains
available from **Control center → Pearl settings**. They apply across all output surfaces without restarting
Pearl. The implementation uses Zig 0.16.0 and the pinned Ghostty GTK/GIO bindings.

## Standalone editor

The Zig `pearl-settings --page appearance` application edits the same session-owned
Pearl draft as the shell preference popup. Advanced exposes the full JSON,
including output overrides, pinned applications and export templates. Use **Apply & save** to save all
Pearl changes, or **Discard** to discard the shared draft. Navigation and normal
close/reopen retain acknowledged drafts while the backend stays running; they
never save implicitly. Invalid JSON stays available in Advanced for repair.

Wallpaper selection uses a normal transient dialog and an asynchronous draft
preview. The application changes its own theme only after a confirmed commit.
External edits trigger conflict review; **Merge changes** combines independent
fields, and Advanced's **View saved JSON** helps review overlapping edits.
A lost backend requires explicit recovery of the local candidate. Closing before
retention succeeds offers Keep open or discarding only untransferred changes.

`pearlctl settings show` opens the standalone application's Overview by default.
Use `--page appearance`, `--page bar`, `--page session` or `--page advanced` for
Pearl preference editors. `control-center show/toggle` continues to open compact
flyouts. The installed executable, desktop ID and icon agree on
`org.aqueous.Pearl.Settings`; Git packages use `pearl-settings-git` and
`org.aqueous.Pearl.Git.Settings`.

Build with `zig build build-settings -Doptimize=ReleaseSafe` (also included in the
normal build). The application never writes preferences directly or starts Pearl.
With the backend absent, launch `pearl-settings` directly for the Retry window;
`pearlctl` requires the running session backend. Closing Pearl itself loses its
in-memory drafts; a still-open Settings window retains its local copy for review.
See [the standalone plan](STANDALONE_SETTINGS_APPLICATION_PLAN.md).

## Theme modes

- **Static Material**: Pearl's dark or light palette. No generator is required.
- **Dynamic Material**: derive a dark/light palette from a hex seed or the selected
  wallpaper. Requires **matugen 4.x**; tested with 4.2.0. Generator failure keeps
  the current appearance and reports the error.
- **GTK theme**: use GTK styling for controls, typography, surfaces and states.
  Leave **GTK theme name** empty to follow the process's normal GTK settings,
  including `GTK_THEME`, user `gtk.css`, and system setting updates. Enter an
  installed theme name to choose it for Pearl alone; the color variant selects
  its dark or default stylesheet. This never changes another application's
  settings. User GTK CSS retains GTK's normal highest priority.

GTK mode uses a small layout stylesheet; Material colors and component styles
are removed from its widget roots. Selected GTK providers are below Pearl's
layout rules and user CSS, but above the system provider. GTK4-compatible themes
are supported, including themes with assets and relative CSS imports in GTK's
normal XDG theme search paths and `~/.themes`. GTK3-only themes cannot style GTK4;
a theme's name alone (for example, one containing “gtk3”) does not determine its
compatibility. Missing themes and CSS parsing errors reject the candidate.
GTK reports deprecated theme syntax separately from parser errors. Native
Aqueous blur remains supported; GTK themes determine their surface opacity, so
an opaque theme hides the blur behind it.

[GTK theme lookup](https://docs.gtk.org/gtk4/class.CssProvider.html),
[GTK named theme loading](https://docs.gtk.org/gtk4/method.CssProvider.load_named.html),
and [matugen usage](https://github.com/InioX/matugen) describe the upstream APIs.

An empty font family uses the Material font fallback in Material modes and
native GTK typography in GTK mode. An explicit family falls back to sans-serif
when unavailable. The default 14-pixel setting does not override GTK mode's
native font size; an explicit nondefault size does. Density and reduced motion
are live settings. The gallery's independent demo controls remain available.

## Preferences and drafts

**Qt applications · QtEngine + Darkly** in Appearance adds optional Qt 5/6 management to this
same draft/Apply workflow. It follows committed Material colors, uses a labelled
static fallback in GTK mode, and can synchronize font, icons, density and selected
Darkly/KDE settings. Management defaults off. Changes affect shared account-wide
Qt configuration; disabling restores only values still owned by Pearl. See
[Qt theming](QT_THEMING.md) for the `qt` preference fields, dependencies, login
activation, conflict review and recovery procedure.

The file is `$XDG_CONFIG_HOME/pearl/preferences.json`, falling back to
`~/.config/pearl/preferences.json`. Opening settings does not create this file.
The validated recovery snapshot is `pearl/last-good.json` in the same directory.

The Appearance and Bar & behavior pages edit a shared draft. Advanced exposes
all fields as JSON, including center widgets, per-connector overrides, popup
limits and export templates. Closing a popup, output removal, or lock hides the
view while retaining the draft in memory. Drafts do not survive process exit.
Apply validates the entire candidate before replacing the file. Invalid JSON,
missing images/themes, failed generators and failed saves retain the draft and
working appearance. Oversized text insertions are rejected without truncating
existing text.

A directory monitor observes file creation, atomic replacement and deletion.
External valid settings update live surfaces; corrupt settings retain the last
working state. Changes invalidate a draft's base revision. **Merge external
changes** performs a three-way field merge: disjoint object fields combine;
arrays and scalar fields are atomic. Changes to the same field that disagree
remain conflicts, with the draft retained. Review the current file alongside
Advanced, resolve overlapping fields to the desired current values, and merge
again, or explicitly discard the draft. Merging never saves automatically.

Saves compare the observed disk content and use GIO's etag check before atomic
replacement. First creation uses a no-replace hard link from a private, fsynced
temporary file. Files written by Pearl are private (0600); recovery/cache/export
snapshots use an atomic rename and directory fsync. Delayed monitor events for
unchanged bytes do not clear errors or regenerate a theme. Unknown fields,
duplicate fields and unsupported versions are rejected rather than silently
removed.

Version 0 migration accepts exactly `{ "version": 0, "dark": false,
"wallpaper": "/absolute/image.png" }`, with the last two fields optional.
It maps to version 1 in memory; only an explicit Apply rewrites the preferences
file in the new format. A corrupt startup file uses the validated recovery
snapshot and is left untouched. If the snapshot's external assets are no longer
usable, Pearl shows a static/solid fallback and reports recovery, while keeping
the snapshot on disk.

## Schema (version 1)

Omitted fields use these defaults:

```json
{
  "version": 1,
  "theme": {
    "mode": "static", "variant": "dark", "seed": "#6750a4",
    "source": "seed", "gtk_name": ""
  },
  "wallpaper": { "mode": "gradient", "path": "", "color": "#141218" },
  "font": "", "font_size": 14, "density": "normal", "reduced_motion": false,
  "bar": {
    "edge": "top", "size": 48,
    "groups": {
      "left": "launcher,workspaces,title", "center": "clock",
      "right": "media,tray,audio,network,battery,notifications,keyboard,control"
    }
  },
  "outputs": [],
  "popup": {
    "dismiss_outside": true, "placement": "anchored",
    "max_width": 720, "max_height": 800
  },
  "exports": []
}
```

`theme.mode` is `static`, `dynamic` or `gtk`; `variant` is `dark` or `light`.
`source` is `seed` or `wallpaper`. Colors require `#RRGGBB`. Wallpaper modes are
`gradient`, `solid`, `cover` and `contain`. GTK mode's gradient default leaves
its wallpaper surface styled by GTK. `density` is `normal` or `compact`.
Popup placement is `anchored` or `centered`; all popup rectangles are clamped to
Aqueous's usable bounds. Escape always dismisses a popup.

Per-output entries use stable connector names from `pearlctl status`, never
Aqueous's temporary output IDs. For example:

```json
{
  "outputs": [
    { "connector": "DP-1", "bar": {
      "edge": "bottom", "size": 48,
      "groups": { "left": "launcher,workspaces", "center": "clock", "right": "audio,control" }
    } }
  ]
}
```

Each override is a complete bar policy with its own schema defaults; it does
not partially inherit the global bar object. Absent connectors retain their
preferences for later hotplug. Widget groups require one launcher and reject
duplicates and unknown names. The supported names are documented in
[DESKTOP.md](DESKTOP.md). The minimum bar size is 32–160 logical pixels; GTK's
actual measurement remains the reservation authority. Existing frame
reservations are checked before applying a conflicting bar edge. The older
`bar set` / `bar groups` commands remain temporary controls; the next preference
application restores the persisted policy.

## Wallpaper and generator bounds

In **Appearance → Wallpaper image**, use **Choose image…** to browse for a PNG
or JPEG. The chooser starts at the current image when one is set. Selecting an
image sets Wallpaper fit to Cover and updates the draft. You can choose Contain
after selecting the image. Click **Apply & save** to use it; cancelling the chooser
keeps the draft unchanged. You can still edit or clear the path directly.

One immutable wallpaper texture is shared across output surfaces and fitted
independently to their geometry. Input is an absolute, local, regular PNG/JPEG
file; symlinks, FIFOs, device files and remote URLs are rejected. Wallpaper file
size, dimensions and pixel count have no Pearl-imposed caps. Images are decoded
at their original resolution off the GTK thread; GPU presentation handles
display scaling. A current texture and one prepared candidate are retained
during a swap, with memory use depending on image size. The wallpaper is global;
output-specific bar settings do not select different images.
Image contents changed in place can be refreshed with `preferences reload`.

There is one GTask worker at a time and a 180 ms event debounce. Obsolete external
loads are cancelled, with only the latest requested configuration retained.
Explicit Apply returns Busy while work is in progress. A 15-second deadline
covers preparation and persistence; generator pipes are capped at 128 KiB and
subprocesses are force-exited and reaped after cancellation or failure. GTK CSS
parsing happens on the main thread before saving and before the atomic provider
swap. Worker application holds drain during shutdown.

Matugen receives an argument vector, an empty Pearl-owned TOML configuration,
`--dry-run`, `--json hex`, an explicit variant and a noninteractive source index.
It cannot run the user's matugen templates, reload hooks or wallpaper commands.
Wallpaper extraction reads a snapshot of the same image bytes that were
validated and decoded. Cache identity includes the input, variant, source,
generator version and Pearl adapter version. Eight bounded disk slots under
`$XDG_CACHE_HOME/pearl/themes` retain validated palettes; collisions cause a
regeneration rather than returning another input's palette. Color roles and
text contrast are checked before installing cached or generated results.
There is no theme polling, recurring timer or generator process at idle.

## Opt-in exports

An export is a name and text template, for example:

```json
{
  "exports": [
    { "name": "terminal.conf", "template": "background={{surface}}\nforeground={{text}}\n" }
  ]
}
```

Files are generated only under `$XDG_CONFIG_HOME/pearl/exports`. Configure the
consumer to include or explicitly link the generated file. Pearl does not
implicitly rewrite GTK, Qt, terminal or Aqueous configuration. No shell hooks or
commands are accepted. Supported tokens are `surface`, `low`, `container`,
`high`, `text`, `secondary`, `primary`, `on_primary`, `primary_container`,
`on_container`, `outline`, `error_color`, and `error_container`, enclosed in
`{{...}}`. Unknown tokens report an export error.

A `.NAME.pearl-owner` sidecar records the exact hash Pearl last wrote. An existing
unowned or subsequently edited file is protected. The first replacement keeps
`NAME.bak`; an existing backup is never overwritten. Export errors are reported
separately from a successful shell save. Removing an export stops future writes
and leaves its files intact. GTK mode has no Material palette to export, so it
retains existing files and reports that condition when exports remain enabled.

## CLI and limits

```sh
pearlctl settings show
pearlctl preferences status
pearlctl preferences apply --revision 4 --text '{"theme":{"mode":"gtk","gtk_name":"Adwaita"}}'
pearlctl preferences reload
```

Apply submits a full configuration (omitted fields reset to defaults), not a
patch. Get the current revision from status; inspect `busy` and `err` after the
queued reply. `appearance` advances only for an installed candidate; `jobs`
helps verify absence of work at idle. Status also reports recovery, cache hits,
export errors and draft revision/dirty state without exposing draft text.
Mutations and settings surfaces obey Pearl's existing Aqueous session/lock gate.

Configuration is capped at 64 KiB and eight JSON nesting levels. There are at
most 16 connector overrides and eight export templates of 8192 bytes each.
Font and theme names are limited to 96 bytes, image paths to 1024, connector
names and each widget group to 128. Font size is 10–24; popup maxima are
320–1280 wide and 320–1600 high, always clamped to the actual output.

The existing control protocol remains limited to 8192-byte frames. CLI Apply's
JSON text is limited to 6500 bytes and must also fit its escaped wire frame.
Use Advanced or edit the file for larger configurations. Status sets
`preferences_truncated` and omits the preferences object above 5500 serialized
bytes; revisions, errors and the file path remain available. This does not
truncate the stored configuration or the settings editor.

Run `zig build test-preferences -Doptimize=ReleaseSafe` in the documented
[private test environment](DEVELOPMENT.md). Evidence and known release limits
are tracked in [PROGRESS.md](PROGRESS.md).
