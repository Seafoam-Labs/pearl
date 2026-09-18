# Community themes · API 1

Pearl can download arbitrary community packages containing exact palettes,
component tokens and restricted CSS. No theme names are compiled into the
selector. GTK4 themes remain available through the existing GTK mode.
All theme discovery, validation, networking, installation and author tools are
implemented in Zig. libcurl supplies HTTPS and libarchive supplies archive IO.
Python is used only by development tests; it is not installed with this feature.

In Settings → Appearance → Community themes, expand **Community repositories
and local archives** to add a repository ID, name and HTTPS index URL. Open
**Community · refresh**, download a release, then open **Installed**. **Use
theme**, **Use colors** and **Use style** edit the shared draft. **Preview**
does not change the committed appearance; **Apply & save** activates the draft.
**Preview current draft** resolves the current palette/style combination. Dynamic
colors generate only on explicit preview, with cancellation and a 15-second
deadline, using private temporary files rather than application configuration.
Repository buttons select among configured sources. Search filters the current
page by name or author; use the next-page button to browse more packages.

The repository list starts empty. No official hosting URL or maintainers have
been selected. An arbitrary compatible HTTPS repository works without rebuilding
Pearl. The `example.org` addresses in the author fixtures are placeholders.

Installation and activation are separate. Downloading/updating/rolling back a
package never changes the current appearance. Refresh Installed and select/apply
the desired version to activate its exact catalog revision. Downloads show phase
and received/total bytes and can be cancelled before publication. Cancellation
after an atomic publication does not undo the completed installation.

## Preferences and ownership

Existing preferences retain their behavior. New `theme` fields are:

| Field | Meaning |
| --- | --- |
| `mode: "package"` | Use a package's exact palette for the selected dark/light variant. |
| `package_id` | Active package, supplying default colors/style. Empty means no package. |
| `palette_id` | Independent palette package; empty inherits `package_id`. |
| `style_id` | Independent style package; empty inherits `package_id`; `pearl.default` uses built-in styling. |
| `catalog_revision` | Catalog hash captured by the picker/preview. A changed catalog rejects Apply. |
| `snapshot_digest` | Backend-managed content hash of committed colors/style. |

Static/dynamic modes can use a package's style while retaining built-in/Matugen
colors. GTK mode bypasses Pearl package styling. Explicit font, density and
reduced-motion settings remain in effect. Package CSS is never applied to lock
authentication surfaces; those receive validated colors with built-in styling.
Qt Follow Pearl, border synchronization and inline exports use the same palette
through their existing opt-in integrations. Package CSS does not style Qt apps.

Discovery scans `$XDG_DATA_HOME/pearl/themes/*` and
`$XDG_DATA_DIRS/pearl/themes/*`. Each child is a package directory. Duplicate IDs
are unavailable rather than silently shadowing each other. Settings refreshes
on request, without idle directory polling. The catalog is limited to 256
directories and 64 MiB of valid package content; metadata is paginated.

Managed packages have receipts under `$XDG_STATE_HOME/pearl/themes`. Updates,
removal and rollback verify owned content. Edits or a different repository's
claim on the same ID stop the operation. An update retains one previous version.
Removing a source preserves its installed packages. The installer uses private
staging, a writer lock, atomic directory publication and a recovery journal.
Interrupted removal verifies surviving files before continuing cleanup.

Committed snapshots live under `$XDG_CONFIG_HOME/pearl/theme-snapshots`, separate
from the disposable metadata cache. They preserve the current theme after its
package is removed or updated, including across restart. Successful commits
prune old unreferenced snapshots while retaining current/previous appearances.
A hard limit of 64 files also bounds orphan snapshots after repeated failed saves.
Missing, corrupt or incompatible snapshots fall back to built-in styling through
the existing recovery path; the saved requested selection is not rewritten.
**Use built-in theme** followed by **Apply & save** explicitly repairs a missing
selection. A failed Apply preserves the draft and working appearance.

For CLI recovery use the existing `pearlctl preferences` draft/apply workflow
with `theme.mode="static"`, empty package/palette/style IDs and an empty catalog
revision. `pearl-themes` manages packages and does not activate preferences.

## Author a package

Start from [the original Meadow example](../themes/examples/meadow/theme.json),
released as CC0. Its colors are authored directly for Pearl roles, with no
third-party theme assets or automatic seed conversion. The corresponding
[fixture index](../tests/fixtures/community/index.json) and archive demonstrate
the release format. Neither is installed as a built-in theme.

`theme.json` is strict JSON: unknown and duplicate fields are errors.

```json
{
  "schema_version": 1,
  "id": "org.example.meadow",
  "name": "Meadow example",
  "author": "Pearl contributors",
  "license": "CC0-1.0",
  "source": "https://example.org/pearl-themes/meadow",
  "asset_version": "1.0.0",
  "requires": {"palette_api": 1, "style_api": 1},
  "palettes": {"dark": "dark.json", "light": "light.json"},
  "style": {"tokens": "tokens.json", "css": "components.css"}
}
```

IDs use lowercase ASCII letters, digits, `.`, `_`, `-`, begin with a letter or
digit and have at most 96 bytes. `pearl.*` is reserved. Versions are three decimal
components without leading zeros. Metadata strings are nonempty UTF-8, at most
256 bytes, without control characters. Either palettes or style must be present;
declare the corresponding API. Unsupported APIs cannot be activated.

Packages are directories or tar.gz archives whose root contains `theme.json`.
Only regular files/directories are allowed: no links, special files, duplicate
archive paths, absolute paths, backslashes or `.`/`..` path components. Limits
are 16 MiB compressed and expanded, 1,024 entries and eight directory levels.
Packages cannot declare commands, installation scripts or runtime hooks.

Each palette JSON supplies exactly these `#rrggbb` roles:

| Roles | Use |
| --- | --- |
| `surface`, `low`, `container`, `high` | Window and component surfaces |
| `text`, `secondary` | Primary and secondary text |
| `primary`, `on_primary` | Accent and text on accent |
| `primary_container`, `on_container` | Accent containers and their text |
| `outline` | Borders |
| `error_color`, `error_container` | Error text and background |

Validation requires 4.5:1 contrast for text/surface, text/high,
secondary/container, on_primary/primary, on_container/primary_container and
error_color/error_container. Colors are preserved exactly; invalid palettes
are rejected. A missing variant is an error, not an automatically recolored
palette. Authors must also visually check controls and focus indicators.

## Style API

All tokens are optional; omission preserves existing styling.

| Token | Bound and behavior |
| --- | --- |
| `card_radius`, `control_radius` | Integer 0–40 px; cards include Settings cards. |
| `border_width` | Integer 0–4 px on cards/buttons. |
| `padding`, `padding_x`, `padding_y` | Integer 0–32 px inside Pearl cards; axis values override `padding`; compact density retains built-in spacing. |
| `title_scale_percent` | Integer 80–160; card titles scale relative to the user's font. |
| `motion_ms` | Integer 0–1,000; reduced motion forces zero. |
| `shadow` | Object: `x`, `y` integers −16–16; `blur` 0–32; `spread` 0–8; `opacity_percent` 0–40. Color follows `surface`. |

Widget margins, Settings row spacing, bar reservations, minimum hit targets and
popup placement remain controlled by Pearl. Tokens do not replace those layout
rules. User font selection/size remain authoritative.

CSS is a small grammar, not arbitrary GTK CSS. Supported component selectors:
`button`, `entry`, `.pearl-card`, `.pearl-island`, `.pearl-dock`, `.pearl-tile`;
each may have one of `:hover`, `:active`, `:checked`, `:disabled`, `:focus-visible`.
Comma-separated selectors are supported. Each branch is structurally validated
and compiled below Pearl's theme root.

Supported declarations: `color`, `background-color`, `border-color` accept hex
colors or `$role$`; `border-radius` accepts 0–32 px; `border-width` accepts
0–4 px; `border-style` accepts `solid`, `dashed`, `none`. Fixed literal colors
remain fixed when the palette changes. Keep foreground/background pairs together.

`@import "buttons.css";` resolves relative to the importing package file.
Imports are expanded from validated package bytes, with cycle checks, at most
four levels, 2,048 total source bytes and 3,072 compiled bytes. Global selectors,
other at-rules, comments, descendant combinators, URLs, external imports,
arbitrary font/layout declarations and opacity are unsupported. Image assets
are not rendered by style API 1. GTK parses the resulting stylesheet before Apply.
Built-in keyboard focus rules remain authoritative. CSS paint choices require
visual review beyond palette contrast validation.

## Native author and repository tools

Build with `zig build build-themes`. The installed executable accepts one JSON
request and prints JSON; `--help` and `--version` are also supported.

```sh
pearl-themes '{"action":"validate","path":"themes/examples/meadow"}'
pearl-themes '{"action":"pack","path":"themes/examples/meadow","output":"/tmp/meadow-1.0.0.tar.gz"}'
pearl-themes '{"action":"import_archive","path":"/tmp/meadow-1.0.0.tar.gz"}'
pearl-themes '{"action":"catalog"}'
pearl-themes '{"action":"preview","theme":{"mode":"package","package_id":"org.example.meadow"}}'
```

`pack` validates content, normalizes archive metadata, refuses an existing output
and returns manifest, archive `sha256` and byte `size`. Write the archive outside
the package directory. `preview` returns resolved palette/tokens/CSS; it neither
generates dynamic colors nor writes preferences. `preview_render` additionally
resolves built-in or Matugen colors, using the same cancellable worker and
15-second deadline as Settings. For a wallpaper source, pass
`wallpaper:{"path":"/absolute/image.png"}`; preview images are bounded to 64 MiB.
GTK theme previews are handled by the existing native GTK path rather than
the package component preview.

Use `source_add` with `id`, `name`, `url`; `source_remove` with `id`; `refresh`
with repository `id` (and optional next-page `url`). `install` requires
`repository`, `id`, `version`, `sha256`, and optionally the cached page `url`.
These must match a release from that page exactly. `remove`/`rollback` take a
package `id`. `catalog` accepts `offset` and a prior `revision` for later pages.

See [repository publishing](THEME_REPOSITORIES.md) for the index contract.
Application profile declarations and full Matugen render data are not accepted
yet: that integration depends on the separate profiles implementation. See
[remaining milestones](CUSTOM_THEMES_IMPLEMENTATION_PLAN.md).
