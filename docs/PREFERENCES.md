# Preferences, wallpaper and themes

**Appearance → Night Light** adds a disabled-by-default `night_light` block to the
shared draft. Temperature and custom local-time schedules save through Apply & save.
Screen warming remains unavailable until Aqueous supplies validated output color
eligibility. See [Night Light](NIGHT_LIGHT.md) for fields, temporary-off overrides,
CLI controls and the upstream prerequisite.

Community package mode and independent `theme.package_id`, `palette_id` and
`style_id` selections are documented in [Community themes](CUSTOM_THEMES.md).
Their catalog/snapshot hashes are backend-managed. Installing a package does
not activate it; selection and Apply & save use the existing shared draft.

[T15 dock and island layouts](DOCK_ISLANDS.md) add persistent app pins, per-output
dock behavior, split bar sections and matching native input/blur regions.

The default-empty `application_launchers` list remembers explicit launcher
choices made through the dock's **Use launcher…** picker:

```json
{
  "application_launchers": [
    {"backend": "xdg", "identity": "org.example.App", "desktop_id": "CustomApp.desktop"}
  ]
}
```

The key is an exact Wayland app ID (`xdg`) or XWayland class (`xwayland`). A choice
applies to every window with that identity. Up to 128 choices are supported;
keys must be unique, nonempty valid UTF-8 of at most 1024 bytes without ASCII
control characters. Desktop IDs follow the same validator as dock pins: nonempty
UTF-8 names ending in `.desktop`, up to 1024 bytes, allowing spaces and Unicode
but excluding path separators and control characters. Existing GIO entries are
required when choosing or adding a pin; unavailable saved IDs remain retained.

Without an explicit choice, matching prefers a unique matching pin, then a unique
matching user-local entry, then a unique system entry. Pin edits update both dock
and Running applications immediately. Resetting an explicit choice returns to
this policy, including any pins that remain saved.

The picker saves immediately and atomically replaces an initiating pin when
needed. **Settings → Bar & dock → Application launchers** can remove choices
through the shared Apply/Discard draft. Resetting a choice preserves explicit
pins. Conflicting edits to the list retain the draft for conflict resolution.
Removed or hidden selected entries remain unavailable rather than falling back
to a different launch command. Existing configuration files default to no
choices; before downgrading to a version without this field, remove
`application_launchers` from the saved configuration because older parsers are
strict about unknown fields.

Open **Pearl Settings** from the launcher or use
`pearlctl settings show --page appearance`. The compact preference editor remains
available from **Control center → Pearl settings**. They apply across all output surfaces without restarting
Pearl. The implementation uses Zig 0.16.0 and the pinned Ghostty GTK/GIO bindings.

## Standalone editor

**Bar & dock → Bar visibility** offers **Always visible** (default) and
**Autohide**. Autohide reveals the bar at its screen edge and hides it 450 ms
after the pointer leaves. An open Pearl flyout keeps its output's bar visible.
Applications use the full available work area even while the bar is revealed.
Choose a mode, then **Apply & save**; Discard leaves the live bar unchanged.

The JSON field is `bar.mode`, accepting `always` or `autohide`. Missing fields
default to `always`. An `outputs[].bar` object replaces the entire default bar:
if that object omits `mode`, that display uses `always`, even if `bar.mode` is
`autohide`. Edit display overrides in Advanced. Visibility changes apply live
and survive restart. See [the implementation plan](BAR_AUTOHIDE_IMPLEMENTATION_PLAN.md).

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

Enable **Window borders follow Pearl theme** in Appearance to synchronize Aqueous
border colors after saving the theme. Focused borders use Material `primary`,
normal borders use `outline`, and urgent borders use `error`. Dynamic themes use
the current matugen palette, including seed, wallpaper, and dark/light changes.
The setting defaults off (`theme.sync_borders` in preferences JSON). GTK mode
pauses synchronization; disabling it keeps the last colors for manual editing in
**Aqueous → Appearance**. Border width is unaffected.

Synchronization waits for pending Aqueous drafts and active operations, then
refreshes and saves only changed border colors through the normal Aqueous
transaction. Errors remain visible in Aqueous settings for review and retry;
failed or uncertain saves are not retried automatically.

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
Aqueous blur remains supported; GTK themes determine their surface opacity in
Automatic mode, so an opaque theme hides the blur behind it.

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

The standalone Appearance, Bar & dock, Plugins and Advanced pages edit one shared
Pearl draft. Bar & dock uses ordered widget selections: **Add widget** opens a
searchable picker, and each widget's actions menu supports reordering, moving
between groups and removal. Launcher is required but movable. Used widgets
cannot be added twice; Clock supports multiple independent instances. Left/right bar edges show Top / Center / Bottom groups;
the saved field names remain `left / center / right`. The preview is a schematic
of the draft; the desktop changes only after Apply & save. Dock and Flyouts
controls are in expandable sections. The legacy Bar & behavior page links to
this standalone widget editor.

This form edits the default bar. Per-connector overrides continue to take
priority and remain in Advanced, along with pinned applications and export
templates. Existing plugin references are retained even if the plugin is
unavailable; adding a discovered plugin requires it to be enabled, approved and
configured for bar placement in Plugins. Removing a widget changes its placement
only. Invalid Advanced text disables structured editing and offers a repair link.
### Multiple time-zone clocks

In **Bar & dock → Add widget → Add another clock**, choose a time zone using the
searchable list or enter its installed identifier (for example `Europe/London`).
`local` follows the system time zone; `UTC` is always available. Each clock has
an optional label, 12/24-hour format and Show date setting. Empty labels use the
zone's city name. The original local clock keeps its existing date and appearance.
Use **Configure clock…** in a clock's actions menu to edit it. **Save to draft**
updates the draft and **Apply & save** updates the bar; Cancel and Discard work
as they do elsewhere in Settings.

Clocks can be reordered and moved independently. Removing one from the bar
retains its settings in the picker. **Delete saved clock** removes an unused
clock's definition. There are at most eight definitions/instances per bar,
including an implicit local clock when placed. Each display override has its
own clock definitions; the default-bar editor preserves those overrides.

`bar.clocks` stores definitions and group strings determine placement:

```json
{
  "bar": {
    "groups": {
      "left": "launcher,workspaces",
      "center": "clock,clock:london,clock:tokyo",
      "right": "control"
    },
    "clocks": [
      {"id":"london","timezone":"Europe/London","label":"London","hour_format":"24h","show_date":false},
      {"id":"tokyo","timezone":"Asia/Tokyo","label":"Tokyo","hour_format":"12h","show_date":false}
    ]
  }
}
```

Bare `clock` uses the reserved `local` definition, or the legacy local-time
configuration if that definition is omitted. To configure that original clock,
add a definition with `id: "local"`; its zone need not remain local. Added
instances use `clock:<id>`; `clock:local` is invalid. IDs are unique within a
bar and contain 1–32 ASCII letters, digits, hyphens or underscores. Labels allow
up to 64 UTF-8 bytes without control characters; zone identifiers allow up to
128 bytes. Multiple clocks may use the same zone. Each instance may be placed
only once across the three groups, and named references require a definition.

Named zones use the installed time-zone database, including daylight-saving
rules. Missing zones display `—` with an explanation instead of silently using
local time. The visual editor rejects unavailable new selections. Tooltips
show the full zone/date/time and current UTC offset. Labels and dates can shorten
on narrow bars while clock times remain readable. Clicking a clock opens the
**local calendar**, including when the clock shows another zone.

Old preference files need no migration. Older Pearl binaries reject the new
`clocks` field and named references because they parse preferences strictly;
remove those fields/references before downgrading.

### Bar background opacity

**Bar & dock → Background opacity** offers Automatic and Custom. Automatic is
the default: Pearl palettes use 86% background opacity when native blur is
available and 100% otherwise; GTK themes retain their own backgrounds. Custom
provides synchronized slider and numeric controls from 0% (transparent) to 100%
(opaque). Text, icons and control states keep their existing rendering, and
the bar remains interactive at 0%.

The field is `bar.background_opacity`, for example
`{"mode":"custom","percent":75}`. The percentage is absolute background alpha,
including without blur. Changes take effect with **Apply & save**; Discard
restores the saved setting. Switching to Automatic retains the last custom
percentage (initially 86) and restores theme backgrounds.

Custom uses a flat background in the active palette's container color. GTK
mode uses the theme's `theme_bg_color` RGB when defined, otherwise the selected
light/dark Pearl container color. Theme background images and existing alpha
are replaced on the bar background in Custom. Other shell surfaces keep their
appearance. Blur remains controlled by the compositor.

Each `outputs[].bar` can contain the same field. These are complete overrides:
omitting `background_opacity` there selects Automatic, even if the default bar
uses Custom. Display overrides remain editable in Advanced.

### Launcher button icon

In **Bar & dock**, open the Launcher's actions menu, then **Change icon…**.
Choose Applications, Grid or System, enter an installed icon-theme name, or use
**Choose PNG…**. The preview reflects the draft; **Apply & save** updates the bar
without restarting. **Discard** restores the saved choice. **Reset to default**
is also a draft edit and restores the original Applications artwork when applied.

Local PNGs must be static, at most 2 MiB, and at most 2048 × 2048 pixels. Keep the
file at the selected absolute path. Pearl preserves its aspect ratio, colors and
transparency; symbolic theme icons use the current theme colors. Missing or
invalid images fall back to the bundled Applications icon and show a warning in
Settings. **Retry** reloads the preview and any live bar already using that same
saved selection, without saving the draft. Files are not watched automatically.

```json
{
  "bar": {
    "launcher_icon": { "kind": "theme", "value": "pearl-view-grid-symbolic" }
  },
  "outputs": [{
    "connector": "DP-1",
    "bar": {
      "edge": "top", "size": 48, "islands": true, "workspace_mode": "large",
      "groups": { "left": "launcher,workspaces,title", "center": "clock", "right": "control" },
      "launcher_icon": { "kind": "file", "value": "/home/user/Pictures/launcher.png" }
    }
  }]
}
```

An omitted icon field means `{ "kind": "default", "value": "" }`. Each output's
bar replaces the default bar completely: an output override with no icon field
uses the bundled icon, not the default bar's custom icon. Per-output editing stays
in Advanced. The feature changes the Applications button only; application icons
inside the launcher and dock retain their desktop-entry artwork.

Schema version remains 1. Before downgrading to a version without launcher icon
support, remove `launcher_icon` from the default bar and every output bar in the
saved configuration; older parsers reject unknown fields.

Bar group strings remain comma-separated.
See the [bar editor implementation](BAR_EDITOR_IMPLEMENTATION_PLAN.md).

Closing a popup, output removal, or lock hides the
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
  "wallpaper": {
    "mode": "gradient", "path": "", "color": "#141218",
    "slideshow": {
      "enabled": false, "folder": "", "interval_seconds": 900,
      "order": "sequential", "transition": "fade", "transition_ms": 420
    }
  },
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

`wallpaper.slideshow` rotates the wallpaper through one folder. `folder` is an
absolute path; only PNG and JPEG files in it are eligible, because the image
pipeline rejects other formats by magic bytes. `interval_seconds` is 10..86400,
`order` is `sequential` or `random`, and `transition` is `none`, `fade`, `slide`,
`rotate`, `cover` or `random` (which re-rolls one animation per change). Enabling
it requires an image fit (`cover` or `contain`) and a folder, otherwise
validation fails with `SlideshowNeedsImageMode` or
`SlideshowFolderRequired`. Each rotation commits preferences through the normal
apply path, so wallpaper-derived colors and matugen profiles regenerate per
slide when the theme follows the image. `reduced_motion` suppresses the
transition. The greeter keeps whatever image was last synced to it.

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

`bar.workspace_mode` accepts `small`, `medium`, or `large` (default). Configure it
through **Bar & dock → Workspaces → ⋯ → Display mode**, then Apply. Small shows
the active workspace and one existing neighbor on each side; Medium shows two
on each side; Large shows all workspaces on that display. Ranges stop at the
first/last workspace without wrapping or filling from the other side. This
setting controls button count, independently of `bar.size` (thickness).

For example, merge `"workspace_mode": "medium"` into the global `bar` object
or an `outputs[].bar` override. An override omitting this field defaults to Large,
even when the global mode is Small. Existing version-1 files remain valid. Older
binaries reject the new field; remove it from global and output bar objects before
downgrading. Removing and re-adding the widget retains its selected mode.

Each override is a complete bar policy with its own schema defaults; it does
not partially inherit the global bar object. Absent connectors retain their
preferences for later hotplug. Widget groups require one launcher and reject
duplicates and unknown names. `running_apps` is the optional **Running applications**
widget; add it through the selection editor to any group. Its scope is all
workspaces and displays, even in a per-output layout. `wallpaper` is the optional
**Wallpaper** widget; it opens a thumbnail browser for the slideshow folder and
applies the clicked image immediately, and its **Choose folder…** button sets
that same folder. There are no additional
widget preferences. Older binaries reject this token, so remove it before a
downgrade. The supported names are documented in
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

**Slideshow** is a section of the same Wallpaper card, below a divider.
**Choose folder…**
browses for a directory; picking one sets Wallpaper fit to Cover when it is not
already an image fit, and seeds Wallpaper image with the folder's first eligible
file when no image is set, so the draft validates. Change every, Order,
Transition and Animation length stay disabled until the switch is on. The folder is rescanned on each
rotation, so adding or removing images takes effect without reloading
preferences; an empty or unreadable folder simply keeps the current wallpaper and
retries at the next interval. A rejected commit (the service is busy, or another
writer moved the revision) also waits for the next interval rather than retrying
immediately.

One immutable wallpaper texture is shared across output surfaces and fitted
independently to their geometry. Input is an absolute, local, regular PNG/JPEG
file; symlinks, FIFOs, device files and remote URLs are rejected. Wallpaper file
size, dimensions and pixel count have no Pearl-imposed caps. Images are decoded
at their original resolution off the GTK thread; GPU presentation handles
display scaling. A current texture and one prepared candidate are retained
during a swap, with memory use depending on image size. The wallpaper is global;
output-specific bar settings do not select different images.
The active image is watched while it supplies the background or wallpaper-derived
colors. In-place edits, atomic replacements and deletion/recreation automatically
refresh it after a 180 ms debounce. Identical contents do not regenerate templates
or rewrite outputs. `preferences reload` also refreshes image contents and retries
watch setup. A removed/unavailable watched directory is reported in application
status; restore it and reload to reattach the watch. No idle polling is used.

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
Font and theme names are limited to 96 bytes, image and slideshow folder paths
to 1024, connector names and each widget group to 128. Font size is 10–24;
slideshow intervals are 10–86400 seconds and animation lengths 100–5000 ms;
popup maxima are
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


## Application themes

The optional top-level `matugen` object defaults to disabled:

```json
{"enabled":false,"colors":{"source":"follow_pearl","seed":"#6750a4"},"applications":{"zed":{"mode":"theme","profile_id":""},"steam":{"mode":"off","profile_id":""}},"snapshot_digest":"","catalog_revision":""}
```

Colors may follow_pearl, seed or wallpaper. Application modes are theme, profile
(explicit profile_id), or off. Omitted applications inherit theme defaults while
management is enabled. Manual and Off choices survive changes to the active theme.
The backend owns snapshot_digest; the picker captures catalog_revision. Controls
share the ordinary draft, Apply/Discard and independent object merge behavior.
Application reconciliation follows preference commit and reports each app’s state
separately. Wallpaper-derived application colors update automatically when the
committed image changes, including with a static/GTK shell and an independent
wallpaper color source. Follow Pearl reuses the shell's complete dynamic palette;
seed and fixed package colors do not change with the wallpaper. Uncommitted
wallpaper selections continue to require Apply.

Automatic refresh preserves committed template bytes and application choices.
It does not adopt changed profile files, rewrite preferences, advance their
revision or apply a Settings draft. Runtime snapshots and per-application
generation counters track color updates separately. Failed input or rendering
retains last-good outputs; ownership conflicts remain per-application errors.
Application outputs are published before Qt integration, and newer wallpaper
events cancel obsolete extraction/rendering. See [application management and
recovery](CUSTOM_THEMES.md#application-management-and-recovery).
