# Create a community theme, step by step

This walkthrough creates a Pearl theme with dark and light colors, widget styling,
and a package you can publish in a public GitHub repository. Start with the
included Meadow example and replace its identity and colors with your own.

## 1. Prepare the author tool

You need a Pearl source checkout, a text editor, and `pearl-themes`. If the tool
is already installed, check it with:

```sh
pearl-themes --version
```

To build it from the Pearl checkout, install the dependencies described in
[Development](DEVELOPMENT.md) and [Compatibility](COMPATIBILITY.md), then run:

```sh
zig build build-themes
export PATH="$PWD/zig-out/bin:$PATH"
pearl-themes --version
```

Run the following shell commands from the root of the Pearl checkout, in the
same terminal. Building requires Zig 0.16.0. A static palette theme does not
need Matugen.

## 2. Copy the example

Choose an unused working directory outside the checkout:

```sh
mkdir -p "$HOME/pearl-theme-work/themes"
cp -R themes/examples/meadow "$HOME/pearl-theme-work/themes/my-theme"
cd "$HOME/pearl-theme-work"
```

Your package starts with these files:

```text
themes/my-theme/
  theme.json       Package identity and asset paths
  dark.json        Dark palette
  light.json       Light palette
  tokens.json      Widget dimensions and motion
  components.css  Component color and border rules
  LICENSE          License for the copied example
```

Keep `theme.json` directly inside the theme folder. All referenced files must
be inside that folder; use ordinary files and package-relative paths.

## 3. Give the theme its own identity

Edit `themes/my-theme/theme.json`:

```json
{
  "schema_version": 1,
  "id": "org.example.my-theme",
  "name": "My Theme",
  "author": "Your name",
  "license": "CC0-1.0",
  "source": "https://github.com/YOUR-NAME/pearl-themes",
  "asset_version": "1.0.0",
  "requires": {
    "palette_api": 1,
    "style_api": 1
  },
  "palettes": {
    "dark": "dark.json",
    "light": "light.json"
  },
  "style": {
    "tokens": "tokens.json",
    "css": "components.css"
  }
}
```

Replace the example ID, author, name, and source URL. Use a unique, stable ID:
lowercase letters, digits, dots, underscores, and hyphens are accepted, starting
with a letter or digit, up to 96 characters. The `pearl.` prefix is reserved.
Versions must contain three numbers, such as `1.0.0`, without prerelease suffixes
or leading zeros.

The example uses CC0. Choose a license for your contribution, include its text
in `LICENSE`, and make the manifest's `license` agree with it. Add an
`ATTRIBUTION.md` identifying the Meadow base and the authors, sources, and
licenses of any additional assets. Preserve applicable attribution and license
notices when adapting someone else's work.

## 4. Edit both palettes

Open `dark.json` and `light.json`. Each needs all 13 color fields, using
`#RRGGBB` values. The copied dark palette is a valid starting point:

```json
{
  "surface": "#101c19",
  "low": "#162822",
  "container": "#1c3028",
  "high": "#263d32",
  "text": "#e8f4e9",
  "secondary": "#c5d8c9",
  "primary": "#a4dfb0",
  "on_primary": "#10391d",
  "primary_container": "#285b37",
  "on_container": "#d3f8dc",
  "outline": "#82998a",
  "error_color": "#ffb4ab",
  "error_container": "#601410"
}
```

| Fields | Purpose |
| --- | --- |
| `surface`, `low`, `container`, `high` | Background and container colors |
| `text`, `secondary` | Main and secondary text |
| `primary`, `on_primary` | Accent and text on the accent |
| `primary_container`, `on_container` | Accent container and its text |
| `outline` | Outlines and separators |
| `error_color`, `error_container` | Error foreground and background |

The validator requires at least 4.5:1 contrast for `text` against both `surface`
and `high`, `secondary` against `container`, `on_primary` against `primary`,
`on_container` against `primary_container`, and `error_color` against
`error_container`. Adjust foreground and background together if validation
reports `InsufficientContrast`.

For a theme with only one variant, remove the other variant's entry from
`palettes` in the manifest. Keep both for this walkthrough.

## 5. Customize widget styling

Edit `tokens.json` to change the copied theme's shape and spacing:

```json
{
  "card_radius": 12,
  "control_radius": 8,
  "border_width": 1,
  "padding_x": 12,
  "padding_y": 10,
  "title_scale_percent": 110,
  "motion_ms": 100
}
```

Token fields are optional. Card and control radii accept 0–40, border width
0–4, padding 0–32, title scale 80–160 percent, and motion 0–1000 milliseconds.
Pearl disables token-based motion when reduced motion is enabled.

Use `components.css` for small component rules. Palette references let the same
rule work with either variant:

```css
button:hover {
  background-color: $primary_container$;
  color: $on_container$;
}
entry:focus-visible {
  border-color: $primary$;
  border-width: 2px;
  border-style: solid;
}
```

Pearl accepts a limited CSS grammar. Selectors are `button`, `entry`,
`.pearl-card`, `.pearl-island`, `.pearl-dock`, and `.pearl-tile`, optionally with
one of `:hover`, `:active`, `:checked`, `:disabled`, or `:focus-visible`.
For this schema-1 theme, use `color`, `background-color`, `border-color`,
`border-radius`, `border-width`, and `border-style`. CSS radius values are
0–32px; CSS border widths are 0–4px. Border styles are `solid`, `dashed`, or
`none`. Keep the CSS source, including imported files, within 2,048 bytes.

For a colors-only package, remove `style` and `requires.style_api` from the
manifest. Colors and widget styles can also be selected independently in Pearl.

## 6. Validate and pack

From `$HOME/pearl-theme-work`, run:

```sh
pearl-themes '{"action":"validate","path":"themes/my-theme"}'
pearl-themes '{"action":"pack","path":"themes/my-theme","output":"my-theme-1.0.0.tar.gz"}'
```

Validation prints the parsed manifest on success. Fix any reported errors before
continuing. Packing validates again, writes the archive, and prints its SHA-256
and byte size. Keep the archive outside the package directory.

| Error | What to check |
| --- | --- |
| `UnknownField` / `DuplicateField` | JSON field names and repeated keys |
| `ThemeAssetMissing` | Manifest and CSS references to missing files |
| `InvalidThemePath` | Absolute paths, `..`, or invalid path components |
| `InsufficientContrast` | The foreground/background pairs in step 4 |
| `InvalidStyleToken` | Token ranges in step 5 |
| `UnsupportedThemeSelector` / `UnsupportedThemeCssProperty` | The supported CSS grammar |

Packages are limited to 16 MiB and 1,024 entries. Symlinks and other special
files are rejected.

## 7. Import, preview, and apply locally

Import the archive:

```sh
pearl-themes '{"action":"import_archive","path":"my-theme-1.0.0.tar.gz"}'
pearl-themes '{"action":"catalog"}'
```

Importing installs the package without changing the active appearance. In Pearl
Settings, open Appearance and find **Community themes**:

1. Choose **Installed** and locate your theme.
2. Choose **Preview** to inspect the sample.
3. Choose **Use theme**, then **Apply & save** to activate it.
4. Check both dark and light variants, keyboard focus, disabled and error
   controls, narrow windows, larger text, compact density, and reduced motion.
5. Capture dark and light screenshots for your contribution.

You can also expand **Community repositories and local archives**, enter the
archive's absolute path, and choose **Import local archive**.

When iterating, edit the working copy, increase `asset_version`, validate, pack
to a matching new filename, and import again. Preview and apply the updated
selection. Keep the ID unchanged so it remains the same theme.

## 8. Publish the theme folder

In a public GitHub repository, commit the complete package at:

```text
themes/my-theme/theme.json
themes/my-theme/dark.json
themes/my-theme/light.json
themes/my-theme/tokens.json
themes/my-theme/components.css
themes/my-theme/LICENSE
themes/my-theme/ATTRIBUTION.md
```

The package must be one directory below `themes/` on the repository's default
branch. Put screenshots elsewhere, such as `screenshots/my-theme/`, to keep
them out of the installable package. Pearl discovers `themes/*/theme.json`
directly; this publishing route needs no index, archive upload, or GitHub release.

To contribute to the built-in community source, prepare a pull request adding
your folder to `Seafoam-Labs/pearl-community-themes`. Check the destination
repository's contribution instructions, and include screenshots and validation
results. The theme becomes discoverable after it reaches the default branch.

To distribute from your own repository, ask users to add its
`https://github.com/OWNER/REPO` URL under **Community repositories and local
archives**, then choose **Community · refresh**, download the theme, and select
**Use theme** followed by **Apply & save**.

## 9. Release updates

Keep the package ID stable and increase `asset_version` whenever published
package files change, including metadata or attribution. Validate and visually
check the new version before publishing it. Pearl remembers published versions
and rejects changed content under an existing ID/version as `MutableThemeRelease`.

For a custom HTTPS index and immutable archive hosting, follow
[Repository publishing](THEME_REPOSITORIES.md). Images and application profiles
require schema 2; start with the palette/style package above, then consult the
[manifest contract](../src/theme/package_model.zig) and the
[bundled application profiles](../themes/profiles/).
