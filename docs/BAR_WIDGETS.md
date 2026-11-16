# Bar widgets and their JSON values

This guide maps every bar widget to the JSON that stores it: where the widget
is placed, which preference fields configure it, and where Settings edits it.
All fields live in `$XDG_CONFIG_HOME/pearl/preferences.json` (schema version 1)
and are validated strictly — unknown keys are rejected.

## Placement: `bar.groups`

Widgets are placed by comma-separated references in three group strings.
Order inside a group is display order. On the top/bottom edges the groups are
**Left / Center / Right**; on the left/right edges the same fields are labeled
**Top / Center / Bottom**. The saved field names never change.

```json
{
  "bar": {
    "groups": {
      "left": "launcher,workspaces,title",
      "center": "clock",
      "right": "media,tray,audio,network,battery,notifications,clipboard,keyboard,control"
    }
  }
}
```

That is also the default layout. Every widget is optional, including Launcher;
an empty group is written as `""`.

Rules enforced by `Groups.validate` (`src/desktop/policy.zig`):

- Each builtin widget appears **at most once** across all three groups.
- Each group string is at most **512 bytes**.
- At most **16 plugin** references and **8 clock** instances per bar.
- Unknown references are rejected; there is no silent fallback.

### Reference forms

| Form | Meaning |
| --- | --- |
| `workspaces`, `clock`, … | A builtin widget id (table below). |
| `clock` | The local clock: the `local` definition in `bar.clocks`, or the legacy local-time configuration when that definition is absent. |
| `clock:<id>` | A named clock instance; requires a matching definition in `bar.clocks`. `clock:local` is invalid — use bare `clock`. |
| `plugin:<id>/main` | An installed plugin widget's main node. The plugin must be enabled, approved and configured for bar placement in Plugins before it can be added; existing references are retained even when the plugin is unavailable. |

## Builtin widgets

Ids are the `policy.Item` enum in `src/desktop/policy.zig`; names and
descriptions come from `src/settings/bar_model.zig`. "Settings" is where the
widget's own options are edited in **Pearl Settings → Bar & dock**.

| JSON id | Name | Widget settings |
| --- | --- | --- |
| `launcher` | Launcher | `bar.launcher_icon` — actions menu → **Change icon…** |
| `workspaces` | Workspaces | `bar.workspace_mode` — actions menu → Display mode |
| `title` | Window title | — |
| `clock` | Clock | `bar.clocks` — actions menu → **Configure clock…** |
| `media` | Media | `bar.media_art` — actions menu → Widget icon |
| `resources` | Resource monitor | `bar.resource_mode`, `bar.resource_series` — actions menu |
| `weather` | Weather | top-level `weather` — actions menu → units and location |
| `dock` | Applications dock | top-level `pinned_apps`, `application_launchers`; dock form rows |
| `running_apps` | Running applications | `bar.running_apps_per_window` (form row) |
| `window_switcher` | Cycle windows | — |
| `overview` | Overview | — |
| `control` | Control center | — |
| `audio` | Sound | — |
| `battery` | Battery | — |
| `network` | Network | — |
| `bluetooth` | Bluetooth | — |
| `notifications` | Notifications | — |
| `tray` | System tray | — |
| `clipboard` | Clipboard | — |
| `keyboard` | Keyboard layout | — |
| `wallpaper` | Wallpaper | — |
| `scheduler` | CPU Scheduler | — |
| `theme` | Theme | — |

Widgets without their own settings are placement-only: adding, moving,
reordering and removing them edits `bar.groups` and nothing else.

## Per-widget settings

### Workspaces — `bar.workspace_mode`

How many workspaces the widget shows. Default `large`.

```json
{ "bar": { "workspace_mode": "small" } }
```

| Value | Shows |
| --- | --- |
| `small` | Active + 1 on each side |
| `medium` | Active + 2 on each side |
| `large` | All workspaces |

### Resource monitor — `bar.resource_mode`, `bar.resource_series`

`resource_mode` chooses the bar presentation (default `icon`); both open the
same detail popup. `resource_series` selects which graphs the popup renders
(all default `true`); sampling and the tooltip are unaffected.

```json
{
  "bar": {
    "resource_mode": "graph",
    "resource_series": { "cpu": true, "gpu": false, "memory": true, "network": true }
  }
}
```

`resource_mode`: `icon` (a bar icon) or `graph` (live sparklines in the bar).

### Media — `bar.media_art`

`true` shows the playing track's album art instead of the media icon.
Default `false`.

```json
{ "bar": { "media_art": true } }
```

### Launcher — `bar.launcher_icon`

The Applications button artwork. Omitted means `{ "kind": "default", "value": "" }`.

```json
{ "bar": { "launcher_icon": { "kind": "theme", "value": "pearl-view-grid-symbolic" } } }
```

| `kind` | `value` |
| --- | --- |
| `default` | Must be `""` — the bundled Applications artwork. |
| `theme` | An installed icon-theme name, 1–128 bytes of letters, digits, `.`, `_`, `-`. |
| `file` | Absolute path to a static PNG, at most 2 MiB and 2048 × 2048. |

This changes only the launcher button; application icons keep their
desktop-entry artwork. Presets never own this field.

### Clock — `bar.clocks`

Definitions live in `bar.clocks`; the group strings decide placement. At most
eight definitions/instances per bar, including an implicit local clock when
placed. Ids are 1–32 ASCII letters, digits, `-` or `_`, unique within the bar.

```json
{
  "bar": {
    "groups": { "center": "clock,clock:london" },
    "clocks": [
      { "id": "london", "timezone": "Europe/London", "label": "London", "hour_format": "24h", "show_date": false }
    ]
  }
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `id` | required | Instance id; `local` configures the original clock. |
| `timezone` | `"local"` | Installed zone identifier (`local`, `UTC`, `Europe/Berlin`, …), up to 128 bytes. |
| `label` | `""` | Up to 64 UTF-8 bytes; empty uses the zone's city name. |
| `hour_format` | `"24h"` | `12h` or `24h`. |
| `show_date` | `false` | Show the date beside the time. |
| `time_format` | `""` | Optional strftime pattern; empty follows `hour_format`. |
| `date_format` | `""` | Optional strftime pattern; empty uses `%a %d %b`. |
| `separator` | `"·"` | Rendered between date and time on horizontal bars, up to 16 bytes. |

Each instance may be placed only once across the three groups. Removing a
clock from the bar retains its definition; **Delete saved clock** removes it.
Presets never own this field.

### Weather — top-level `weather`

The weather location is a **global** preference shared by every output's bar;
only the widget's placement is per-bar.

```json
{ "weather": { "location": "Berlin", "latitude": 52.52, "longitude": 13.405, "units": "fahrenheit" } }
```

`units` is `celsius` (default) or `fahrenheit`. Coordinates are validated;
the location must be nonempty.

### Applications dock — `pinned_apps`, `application_launchers`

The `dock` widget shows pinned and running applications for its display.
Pins are top-level desktop ids (at most 16, unique, ending in `.desktop`):

```json
{ "pinned_apps": ["org.example.App.desktop"] }
```

Explicit launcher choices are remembered in `application_launchers`
(see [PREFERENCES.md](PREFERENCES.md#appearance-services)). Drag-to-reorder
in the dock edits the pin order. The standalone dock's own settings are the
`dock` block below.

### Taskbar behavior — `bar.running_apps_per_window`

`true` gives one taskbar button per window instead of grouping by application
(the applications strip hosted by the `dock` or `running_apps` widget).
Default `false`. Edited as the form row **One taskbar button per window**.

## Bar and dock form settings

These are edited as form rows on the Bar & dock page (not per widget). The
field specs live in `src/settings/bar_dock_fields.zig`.

| JSON field | Values | Default |
| --- | --- | --- |
| `bar.mode` | `always`, `autohide` | `always` |
| `bar.edge` | `top`, `bottom`, `left`, `right` | `top` |
| `bar.size` | 32–160 px | 48 |
| `bar.radius` | 0–48 px corner radius | 14 |
| `bar.islands` | bool — separate islands vs continuous bar | `true` |
| `bar.attached` | bool — attach to the screen edge | `false` |
| `bar.background_opacity` | `{ "mode": "automatic" \| "custom", "percent": 0–100 }` | automatic, 86 |
| `dock.enabled` | bool | `true` |
| `dock.edge` | `top`, `bottom`, `left`, `right` | `bottom` |
| `dock.mode` | `always`, `intelligent`, `autohide` | `intelligent` |
| `dock.icon_size` | 24–64 px | 40 |
| `dock.margin` | 4–32 px | 8 |
| `dock.opacity_sync` | bool — follow the bar's opacity | `true` |
| `dock.background_opacity.percent` | 0–100, used when sync is off | 86 |

`dock.background_opacity.mode` exists in the schema but is shell-derived:
with `opacity_sync` off, the shell always applies the percent as a custom
alpha, so Settings exposes only the percent. The dock edge also moves away
from the bar edge automatically when both request the same edge.

Flyout behavior (`popup.dismiss_outside`, `popup.placement`, `popup.max_width`,
`popup.max_height`) shares the same form but is not a bar or dock setting.

## Layout presets

Presets (`src/config/bar_dock_presets.json`) place widgets with the same builtin
ids, as arrays per group:

```json
{
  "id": "macos",
  "preview": "/org/aqueous/Pearl/previews/macos.png",
  "bar": { "edge": "top", "size": 32 },
  "widgets": {
    "left": ["workspaces", "title"],
    "center": [],
    "right": ["media", "tray", "network", "battery", "notifications", "control", "clock"]
  },
  "dock": { "enabled": true, "edge": "bottom" }
}
```

`preview` names the tile's clickable image in the GResource bundle
(`resources/previews/`, registered in `resources/pearl.gresource.xml`). The
shipped files are ~10 KB PNG placeholders; clicking the small preview opens it
large in a modal window. To use real 4K screenshots later, drop the capture
into `resources/previews/`, register it in the manifest and point `preview` at
it — no code change. Prefer AVIF (smallest 4K size) or WebP; decoding uses the
installed gdk-pixbuf loaders, and PNG always works. Paths are validated: they
must stay under `/org/aqueous/Pearl/previews/` and end in `.png`, `.webp`,
`.avif`, `.jpg` or `.jpeg`.

`bar` and `dock` keys are matched against the live preference fields and
`widgets` against the live widget enum, so new settings and widgets need no
preset code change. A preset may not own `groups`, `clocks` or `launcher_icon`;
plugin and named-clock references keep their place in the group they were in.
The top-level `bar_dock_preset` records the last applied preset id and clears
to `""` when any bar/dock setting or widget placement changes. See
[PREFERENCES.md](PREFERENCES.md#standalone-editor).

## Per-display overrides

`outputs[].bar` **replaces the entire default bar**, including `groups` and
every widget setting: an override that omits a field uses that field's default,
not the default bar's value. `outputs[].dock` is optional and falls back to the
top-level `dock`. `bar_hidden_outputs` switches the bar off per connector
independently of the overrides. Overrides are edited in Advanced.

```json
{
  "outputs": [
    {
      "connector": "DP-1",
      "bar": { "edge": "top", "size": 64, "groups": { "left": "launcher", "center": "clock", "right": "control" } },
      "dock": { "edge": "left", "icon_size": 64 }
    }
  ],
  "bar_hidden_outputs": ["DP-2"]
}
```

## Adding future options

- **New bar/dock setting**: add the field to `prefs.Bar` or `dock_policy.Config`,
  then add a form row in `src/settings/bar_dock_fields.zig` or widget editor
  coverage in `bar_view.zig`/`bar_model.zig`. The unit test
  *"every bar and dock preference has a Settings control"* fails at compile
  time until the new field is editable, and also rejects form rows that name
  no field or offer invalid enum choices. Presets pick the field up
  automatically.
- **New builtin widget**: add the id to `policy.Item`, its name/description/icon
  to `bar_model.metadata`, any per-widget settings as above, and a row to this
  guide. Presets and the widget picker match the live enum, so no preset code
  change is needed.
- Document new fields in [PREFERENCES.md](PREFERENCES.md); older strict
  parsers reject unknown fields, so note downgrade removal there.
