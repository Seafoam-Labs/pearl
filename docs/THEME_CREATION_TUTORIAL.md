# Create a Pearl theme from three colors

Create one palette file, select it once, then save color edits to update Pearl.
You can use Settings or a text editor. Local palettes need no package manifest,
release version, stylesheet, application templates, or source checkout.

This tutorial covers editable palettes, importing Noctalia colors, application
themes, and publishing. For custom widget geometry, CSS, images, or bundled
application profiles, continue with [the package authoring guide](CREATE_COMMUNITY_THEME.md).

## 1. Create your first palette in Settings

Open **Pearl Settings → Appearance**. Under **Palette and widget style**, expand
**Create and edit palettes**.

1. Set **Filename** to `meadow` and **Palette display name** to `Meadow`.
2. Leave the starter colors, or enter your own **Background**, **Text**, and
   **Accent** as `#RRGGBB` values.
3. Check the sample and derived colors. Invalid colors or insufficient contrast
   produce a diagnostic; the sample retains its previous valid appearance.
4. Click **Create**. This writes a new file and refuses to replace an existing
   palette with that filename.
5. Find **Meadow** in the installed palette list, click **Use theme**, then
   **Apply & save**. Use **Widget style · use Pearl default** if you previously
   selected another package's widget styling.

The file is `$XDG_CONFIG_HOME/pearl/palettes/meadow.json`, normally
`~/.config/pearl/palettes/meadow.json`. The local identity is
`local.palette.meadow`; the display name can change without changing that identity.
Use lowercase letters, digits, dots, underscores, and hyphens in filenames, with
a letter or digit first. Keep the filename stem at most 80 characters.

For later edits, choose **Edit colors** on that palette. Basic fields change the
editor's isolated sample. **Save palette** writes the file; saved changes to the
currently selected local palette update Pearl and its enabled application themes
automatically. **Discard palette edits** restores the editor's last loaded/saved
source. These buttons operate on the palette file independently of the shared
preferences draft and its **Apply & save** and **Discard** buttons.

To make a copy, change **Filename** and click **Duplicate**. To edit externally,
choose **Open file**. Saving detects an external edit since the file was loaded:
on `Conflict`, reopen **Edit colors**, then reconcile your changes before saving.

## 2. Create the same palette from a terminal

Use the installed `pearl-themes` tool:

```sh
pearl-themes --version
pearl-themes init meadow
palette="${XDG_CONFIG_HOME:-$HOME/.config}/pearl/palettes/meadow.json"
pearl-themes validate "$palette"
pearl-themes preview "$palette" --watch
```

If you already created `meadow` in Settings, skip `init` or use another filename.
Successful commands print JSON. Validation errors print structured diagnostics
and exit with status 1. The GUI preview requires a graphical session; creating,
validating, importing, and exporting work without a display. Matugen is not
required to create a static shell palette.

The starter is the entire authoring file:

```json
{
  "name": "Meadow",
  "dark": {
    "surface": "#101c19",
    "on_surface": "#e8f4e9",
    "primary": "#a4dfb0"
  }
}
```

Edit it in your preferred editor. `name` is optional; without it, Pearl uses the
filename stem. At least one variant is required, and each supplied variant needs
`surface`, `on_surface`, and `primary`. Colors must have exactly six hexadecimal
digits after `#`. JSON comments, unknown keys, and duplicate keys are rejected.
The source size limit is 64 KiB.

The watched preview refreshes after saved edits, including atomic file replacement.
It has a dark/light toggle and does not select a theme or write application
configuration. Saving a file that is already active still updates the running
Pearl through its normal local-palette watcher.

Open Settings, select the palette, and **Apply & save** when ready. Dropping a
valid JSON file into the palette directory also adds it to the list automatically.
Saving an unselected palette updates the catalog and leaves the active colors alone.

## 3. Add an independent light variant

With only `dark`, both modes use that exact resolved palette. With only `light`,
both use the light palette. Pearl reports this fallback; it does not manufacture
an opposite variant. To design both, use:

```json
{
  "name": "Meadow",
  "dark": {
    "surface": "#101c19",
    "on_surface": "#e8f4e9",
    "primary": "#a4dfb0"
  },
  "light": {
    "surface": "#f5fbf6",
    "on_surface": "#17231a",
    "primary": "#28633b"
  }
}
```

In Settings, choosing **Light** in the author editor initially displays the
fallback colors. Editing a basic color creates that variant. Use the normal
Appearance dark/light setting to change the active mode, followed by **Apply & save**.

## 4. Refine derived colors

Expand **Advanced colors and terminal palette · JSON** in Settings, or edit the
file directly. Explicit values always retain their supplied colors. Omitted
values follow palette compiler version 1:

| Role | Default |
| --- | --- |
| `surface_container_low`, `surface_container`, `surface_container_high` | Surface mixed toward text by 4%, 8%, 12% |
| `surface_container_highest`, `surface_bright` | Surface mixed toward text by 16% |
| `background`, `surface_dim`, `surface_container_lowest` | Surface |
| `surface_variant` | Surface mixed toward text by 8% |
| `on_surface_variant` | Surface mixed toward text by 75%; text if the mix is unreadable |
| `outline`, `outline_variant` | Surface mixed toward text by 55%, 25% |
| `secondary`, `tertiary` | Primary accent |
| Accent containers | Surface mixed toward the corresponding accent by 20% |
| `on_primary`, `on_secondary`, `on_tertiary` | Whichever of black/white has higher contrast |
| Foregrounds on accent containers | Text if readable; otherwise black/white |
| Accent fixed/fixed-dim roles | Corresponding accent; foregrounds use black/white |
| `hover`, `on_hover` | High surface and text |
| Error colors and ANSI colors | Pearl's built-in Material defaults for the supplied mode |

Mixing uses rounded sRGB channel values. Derived surface levels fall back to
`surface` if they make the text unreadable. Other Material roles include
`on_background`, `on_error`, `on_error_container`, `inverse_surface`,
`inverse_on_surface`, `inverse_primary`, `shadow`, `scrim`, `surface_tint`, and
`source_color`. Each accent (`primary`, `secondary`, `tertiary`) supports
`<accent>_fixed`, `<accent>_fixed_dim`, `on_<accent>_fixed`, and
`on_<accent>_fixed_variant`. Together with the roles in the table, these are all
accepted color roles. Optional terminal fields are described below.

Pearl checks a 4.5:1 contrast ratio for text on surface/high surface, secondary
text on container, each accent's foreground and container foreground, the error
color on its container, and the hover foreground. Review other advanced role
pairs and terminal colors in their target applications as well.
Diagnostics identify the JSON path and, for contrast failures, the background,
measured ratio, required ratio, and a suggested readable foreground. Pearl
rejects unreadable explicit pairs instead of changing the supplied values.

For example, add a distinct secondary accent and hover color:

```json
{
  "name": "Meadow",
  "dark": {
    "surface": "#101c19",
    "on_surface": "#e8f4e9",
    "primary": "#a4dfb0",
    "secondary": "#91cef4",
    "hover": "#244136",
    "on_hover": "#e8f4e9"
  }
}
```

In this authoring format, `secondary` is an accent. Pearl's older package palette
field named `secondary` means secondary text; export maps `on_surface_variant`
to that legacy field and retains the accent separately for application templates.

## 5. Supply terminal colors

Add `terminal` within each variant. All of its fields are optional:

```json
{
  "name": "Meadow Terminal",
  "dark": {
    "surface": "#101c19",
    "on_surface": "#e8f4e9",
    "primary": "#a4dfb0",
    "terminal": {
      "background": "#101c19",
      "foreground": "#e8f4e9",
      "cursor": "#a4dfb0",
      "cursorText": "#101c19",
      "selectionBg": "#285b37",
      "selectionFg": "#e8f4e9",
      "normal": { "red": "#ef9393", "green": "#a4dfb0" },
      "bright": { "red": "#ffc4c4", "green": "#d3f8dc" }
    }
  }
}
```

Both ANSI groups accept `black`, `red`, `green`, `yellow`, `blue`, `magenta`,
`cyan`, and `white`. Normal and bright overrides are independent. Missing slots
use Material/Base16 defaults; normal black follows surface, and both white slots
follow text. Missing special colors use surface/text, primary/on-primary, and
primary-container/on-container pairs. Ghostty, Kitty, Foot, Alacritty, and WezTerm
templates consume these explicit terminal values. Existing fixed render-data
packages without terminal roles keep the adapters' previous default mappings.

## 6. Theme applications with the same palette

Under **Appearance → Application themes**, enable management and choose
**Use Material defaults**, then **Apply & save**. Keep application colors on
**Follow Pearl**. Local palettes and exported color-only packages supply complete
render input to the reusable built-in templates. You do not need a copy of each
application template in your palette.

Matugen 4.x is required for application rendering. Manual profile choices and
**Off** take priority over defaults. Independent seed or wallpaper application
colors keep their chosen source. qt5ct/qt6ct require explicit profile selection;
Steam and Fluxer currently support dark mode only.

Read each row's output path and activation instructions. For example, Ghostty
uses `theme = pearl-material`; Kitty imports its reported theme file. Some
applications require reload, restart, or theme selection. See
[all application defaults and activation steps](BASE_MATERIAL_PROFILES.md).

The compiler supplies exact semantic colors and terminal slots. Its six Matugen
transport tone ramps are inherited from Pearl's Material defaults, rather than
generated from your palette. The bundled templates do not use those ramps. If
an advanced custom template needs genuine custom tone ramps, use dynamic
generation or a full fixed-render-data package.

## 7. Import Noctalia colors

Import a palette JSON into a new local filename:

```sh
pearl-themes import "/path/to/Noctalia Palette.json" --name noctalia-meadow
```

In Settings, expand **Import and export**, enter the absolute input path, set a
new **Filename**, and click **Import palette**. Import validates colors and
normalizes aliases; it refuses to overwrite an existing local file. Select the
result separately to activate it.

| Noctalia name | Pearl authoring role |
| --- | --- |
| `mPrimary`, `mOnPrimary` | `primary`, `on_primary` |
| `mSecondary`, `mOnSecondary` | `secondary`, `on_secondary` accents |
| `mTertiary`, `mOnTertiary` | `tertiary`, `on_tertiary` |
| `mError`, `mOnError` | `error`, `on_error` |
| `mSurface`, `mOnSurface` | `surface`, `on_surface` |
| `mSurfaceVariant`, `mOnSurfaceVariant` | `surface_variant`, `on_surface_variant` |
| `mOutline`, `mShadow` | `outline`, `shadow` |
| `mHover`, `mOnHover` | `hover`, `on_hover` |

Different values for an alias and its canonical role produce
`ConflictingPaletteAlias`. Remove the conflicting field and validate again.
Unsupported fields must be removed or translated explicitly. Import covers
palette colors; Noctalia templates, hooks, and shell configuration are separate.

## 8. Export a community package

Keep iterating locally without release metadata. When ready to distribute, create
`metadata.json` with your stable identity, version, and actual licensing text:

```json
{
  "id": "org.example.meadow",
  "author": "Your name",
  "license": "MIT",
  "source": "https://github.com/your-name/pearl-palettes",
  "version": "1.0.0",
  "license_text": "Replace with the complete license and copyright notice for your palette.",
  "attribution": "Describe the original palette and credit any borrowed colors or assets."
}
```

Replace every placeholder before publication. Use your own ID outside the
reserved `pearl.*` and `local.palette.*` namespaces. Versions use three numeric
components. License and attribution text are required for publication.

```sh
pearl-themes export "$palette" --output ./meadow-package --metadata ./metadata.json
pearl-themes validate ./meadow-package
pearl-themes '{"action":"pack","path":"./meadow-package","output":"./meadow-1.0.0.tar.gz"}'
```

Export requires a new output directory and preserves the source. It writes a
validated schema-2 package containing `theme.json`, `dark.json`, `light.json`,
`render-data.json`, `LICENSE`, `ATTRIBUTION.md`, `palette-source.json`, and
`palette-hover.json`. The small hover file preserves the additional hover pair
for current Pearl clients without changing the legacy 13-color palette format.
Both variants are exported, including the documented fallback when only one was
authored. Existing schema-2 clients can read the package; this Pearl release adds
reusable application defaults for color-only packages.

To test installation, use **Community repositories and local archives** in
Settings, or:

```sh
pearl-themes '{"action":"import_archive","path":"./meadow-1.0.0.tar.gz"}'
```

Installed releases retain their committed appearance until explicitly adopted.
They are separate from your editable local palette. Continue editing the source,
increment the publication version for a new release, and export into a new directory.

## 9. Publish a compact palette in a GitHub repository

A public repository can contain compact sources alongside richer packages:

```text
palettes/
  meadow.json
themes/
  a-theme-with-custom-widgets/
    theme.json
    ...
```

Put the metadata object from step 8 under a top-level `publication` key in
`palettes/meadow.json`, beside `name`, `dark`, and `light`. The metadata fields
and color format are identical. Only flat `palettes/*.json` entries are discovered.
Commit the source to your public repository and configure its GitHub repository
URL in Pearl's community browser. Refresh explicitly to discover releases.

Pearl pins source bytes to a Git commit and blob hash, includes the compiler
identity in the release digest, and compiles the palette through its existing
install/receipt/rollback pipeline. Source changes under the same publication ID
and version are rejected as `MutableThemeRelease`; increment the version when
publishing changes. Repository refresh and installation use the existing bounded
downloads and validation. Compact installed palettes are immutable packages.

For an archive/index repository, `publish_build` also accepts a compact JSON
source as a record's `path`, provided it includes `publication`. See
[repository publishing](THEME_REPOSITORIES.md) for the input specification, archive
URLs, pagination, and publication steps. The native builder creates local artifacts;
you publish those files through your normal repository workflow.

## 10. Diagnose an editing problem

| Symptom | Next action |
| --- | --- |
| Palette is absent from the list | Check the local directory, filename, `.json` extension, and `pearl-themes validate FILE` |
| `InvalidColor` or `MissingPaletteRole` | Supply each required role as `#RRGGBB` in every authored variant |
| `InsufficientContrast` | Correct the reported foreground/background pair; use the suggested foreground as a starting point |
| `Conflict` while saving | Reload Edit colors and reconcile external changes |
| `PaletteAlreadyExists` | Choose a new filename or load the existing palette for editing |
| Editing has no active effect | Select the local palette and Apply & save; then Save palette or save the file |
| Both modes look identical | Author both variants instead of relying on single-variant fallback |
| Application colors do not follow | Enable management, select defaults or a profile, choose Follow Pearl, and inspect the row's status and activation instructions |
| Application file conflict | Preserve/reconcile the user edit before retrying; Pearl will not overwrite it |
| `PublicationMetadataRequired` | Provide `--metadata` or a top-level `publication` object |
| `MutableThemeRelease` | Increment `publication.version` for changed published source |

Malformed, unreadable, or deleted active files preserve the last valid palette
and report an error. Pearl retains the latest valid local source and appearance
for restart recovery. Fix and save the source to resume live updates. Renaming
the file creates a new identity, so select the renamed palette explicitly.
