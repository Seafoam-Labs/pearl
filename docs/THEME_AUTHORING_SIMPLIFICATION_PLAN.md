# Simplify theme creation around palettes

Status: implemented, October 6, 2026. The design below records the author contract
and delivery sequence. Follow [the complete tutorial](THEME_CREATION_TUTORIAL.md)
for the shipped Settings, CLI, live editing, and publication workflows.

Make the ordinary authoring workflow **create one JSON file → select it → edit
and preview**. Separate colors from application templates and optional widget
styling. Keep the existing package format available for distributing richer
themes, with export tooling handling its metadata and file layout.

## Reference and current friction

Noctalia's current design uses a custom palette JSON under its config directory,
with inline dark/light variants. Application templates are configured separately
and reused across palettes. Its palette documentation lists 16 shell roles and
optional terminal colors; a missing light variant uses the dark colors in both
modes. These are the behaviors to adopt, rather than copying its entire runtime
or template engine:

- [Custom palettes and roles](https://docs.noctalia.dev/noctalia/theming/palette/).
- [Palette sources and live changes](https://docs.noctalia.dev/noctalia/theming/).
- [Reusable application templates](https://docs.noctalia.dev/noctalia/theming/app-theming/).

Pearl's [current walkthrough](CREATE_COMMUNITY_THEME.md) starts with a source
checkout and a six-file example. Even a colors-only package needs a manifest,
palette files, identity, version and API declarations. Iteration is documented as
incrementing the version, validating, packing, importing, previewing and applying.
The CLI also requires JSON requests for ordinary author commands.

There is a second obstacle: `theme.zig` accepts 13 shell colors, but
`render_data.zig` requires a complete Matugen document with semantic roles,
Base16 colors and six tone palettes. A static package without that document cannot
supply Follow Pearl colors to the existing application renderer. This gap must
be solved alongside the simpler file format.

## Proposed author contract

Discover editable palettes at `$XDG_CONFIG_HOME/pearl/palettes/*.json`, defaulting
to `~/.config/pearl/palettes/`. A minimal proposed file is:

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

`name` is optional and defaults to the filename. At least one nonempty variant
is required. Each authored variant requires `surface`, `on_surface` and
`primary`; other roles have documented defaults. A file with just dark or light
uses that same resolved variant for both modes. Expose that fallback in Settings;
do not pretend to have generated an independently designed opposite variant.

Use Material role names in this new format: `on_surface`,
`on_surface_variant`, `surface_container_low`, `surface_container`,
`surface_container_high`, `primary`, `on_primary`, `primary_container`,
`on_primary_container`, `outline`, `error`, and `error_container`, with optional
secondary/tertiary accents, hover roles and terminal colors. Preserve the
existing 13-role names in legacy package files.

Support direct import of Noctalia's documented `mPrimary`, `mOnPrimary`,
`mSurface`, etc. through an explicit alias table. Reject conflicting aliases
with their exact JSON paths. In particular, **Noctalia's `mSecondary` is an
accent; Pearl's legacy `secondary` is secondary text**. Map `mOnSurfaceVariant`
to that legacy text role, and retain `mSecondary` as a separate template accent.
Do not claim compatibility with Noctalia templates, hooks or configuration.

Local files need no manifest, ID, author, license, release version, CSS or API
declarations. Derive a stable local identity from the filename in a dedicated
namespace; renaming creates a new identity. Community publication requires a
stable explicit ID and licensing metadata, collected during export. Keep parser
and expansion versions internal and include them in content digests.

## One palette resolver

Add a pure Zig palette parser/resolver that produces a normalized color model.
Use that same result for shell colors, sample previews, exports and application
render input. Avoid duplicating derivation in Settings and the renderer.

Resolution precedence is: explicitly authored role → documented derivation from
authored roles → mode-specific built-in default. Explicit colors always retain
their values. Version and fixture-test the expansion rules:

- Choose a readable `on_primary` when omitted; derive container backgrounds and
  secondary text from the authored surface/text/accent colors.
- Use bounded, documented color mixing for surface levels and containers.
  Validate the resulting contrast before accepting the resolved palette.
- Let secondary/tertiary accents default to primary. Resolve their foreground,
  container and fixed roles consistently. Allow independent overrides.
- Provide usable error and ANSI defaults. Preserve supplied terminal normal and
  bright colors, selections and cursor colors; never treat a primary accent as a
  complete terminal palette.
- Return diagnostics with variant, role, offending value or contrast pair, ratio
  and required threshold. Preserve existing package contrast rules. Do not
  silently recolor explicit values; offer a suggested fix in the author UI.

The normalized model retains the broader semantic colors that do not fit into
`theme.Palette`; projection into the existing 13 shell fields happens once.
Existing schema-1/2 packages keep their exact palettes and fixed render data.

For application rendering, build a Matugen-compatible input from the resolved
roles and terminal/Base16 mapping. Audit every bundled template's inputs before
freezing this contract. The current bundled templates use semantic and Base16
roles; inspection found no `palettes.*` tone-ramp references. Genuine tone ramps
remain an advanced capability supplied by existing fixed render data or dynamic
generation. Do not label mixed or inherited colors as authored tone ramps.

Prototype the JSON import path against the supported Matugen version first. If
it requires tone maps even for these templates, keep the existing complete
default document as the transport foundation, overlay all resolved semantic and
Base16 values, and record the inherited ramp capability explicitly. Advanced
templates requiring custom ramps must report that limitation. Separate validation
of this compiled input from the stricter legacy fixed-render-data contract.
Never regenerate the authored palette from a single seed as a substitute.

Static shell palette creation remains independent of Matugen. Application
templates continue using the existing Matugen renderer and private config.

## Integrate with existing discovery and application state

Extend catalog entries with a source kind: directory package or editable palette
file. Provide common access to identity, display name, capabilities, digest and
normalized colors. Only directory packages expose package assets and profiles.
Adapt `resolve.zig` and consumers instead of inventing public package metadata
for local files or building another theme installation pipeline.

Reuse the bounded discovery worker and GIO watches. Monitor the new config root,
including creation of an initially missing directory and atomic file replacement.
Apply the existing file/JSON bounds and reject ambiguous IDs and invalid fields.
Include resolved defaults and compiler version in digests and cache identities.

Selecting a palette still uses the shared Settings draft and Apply & save.
After an editable local palette is committed, valid saves to that selected file
update the active colors automatically. This source-specific behavior must be
visible in Settings. Unselected edits only refresh the catalog. Installed release
packages retain explicit adoption of updates.

Use a separate color generation tied to the committed selection, as the current
wallpaper update path does. Cancel stale work, check selection identity before
publishing, capture immutable bytes, and retain the latest valid resolved snapshot
for restart. An invalid, partially written or deleted file keeps the last valid
appearance and reports its diagnostic. Returning to a valid file retries.
Opening, editing or discarding a Settings draft cannot publish draft colors or
change application destinations. Handle catalog changes without overwriting
unsaved drafts.

Palette selection supplies colors independently of template choice. For new
palette selections, provide the existing built-in application profiles as reusable
defaults when application management is enabled. Manual profile choices and Off
retain priority; management remains opt-in. Palette changes rerender committed
templates using existing snapshots, cancellation, ownership journals and
per-application failure handling. Reuse `application_adapters.zig` for destinations.

Keep widget style as a separate advanced choice. A plain palette uses Pearl's
default style. Authors who want CSS, images or custom profile bundles can export
an existing schema-2 package. Supporting arbitrary application destinations or
contributed commands is a separate project, unnecessary for simple palettes.

## Author tools and Settings

Add ordinary subcommands to `pearl-themes`, keeping JSON requests compatible:

```sh
pearl-themes init meadow
pearl-themes validate ~/.config/pearl/palettes/meadow.json
pearl-themes preview ~/.config/pearl/palettes/meadow.json --watch
pearl-themes import noctalia-palette.json --name meadow
pearl-themes export ~/.config/pearl/palettes/meadow.json --output ./meadow-package --metadata ./metadata.json
```

These commands are implemented. `init` writes the starter palette in the user config
root, refuses overwrite, and works from an installed binary. `preview --watch`
uses an isolated component preview and writes no active preferences or application
files. Import normalizes supported Noctalia aliases and reports unsupported fields.
Export reads release metadata from `--metadata FILE` or the source's `publication`
object and creates a validated legacy-compatible package
with generated palette/render-data files; authors edit their source JSON.

In Appearance, make **Palette** the main selection with built-in, wallpaper,
local and community sources. Add **Create**, **Duplicate**, **Import**,
**Edit colors**, **Open file** and **Export**. Start the editor with the three
required colors, a variant selector and live sample. Put other roles, ANSI colors
and diagnostics under an expanded view. Show authored versus derived values.
Show widget styles and per-application template choices separately.

Saving an inactive palette creates/updates its file without selecting it. Saving
an active local palette triggers the documented live update. A draft-only editor
preview stays isolated until Save; Discard leaves the file and committed state
untouched. Display application activation requirements using existing status rows.

## Delivery sequence

| Step | Main changes | Acceptance gate |
| --- | --- | --- |
| S1: contract and resolver | New pure `src/theme/palette_model.zig` and `palette_resolver.zig`; projection in `theme.zig`; input bridge in `render_data.zig` | Three-color file resolves offline; alias mappings and contrast diagnostics are correct; supported Matugen imports resolved input and preserves exact authored colors |
| S2: local files and iteration | `catalog.zig`, `discovery.zig`, `resolve.zig`, preferences/service and snapshot integration | Drop-in file appears without restart; selected valid edits apply; invalid edits/restart retain valid colors; draft and stale-worker protections pass |
| S3: author CLI | `src/themes_main.zig`, `commands.zig`, isolated watched preview, import/export | Installed tool creates, validates, previews and exports without source checkout, version bumps or archives during editing; existing JSON requests still work |
| S4: shared application colors | `theme_provider.zig`, `application_profiles.zig`, existing built-in profiles/adapters | An arbitrary local palette themes shell and enabled applications; manual/Off precedence and journals survive updates; all supported bundled template/variant combinations render |
| S5: Settings authoring | `themes_view.zig`, appearance editor protocol and palette editor | Create → edit → save → select works with keyboard and large text; active-file editing and Discard have the specified effects |
| S6: distribution and docs | Native export, `github.zig`, `repository.zig`, `publishing.zig`; author guide and examples | Compact community files are discovered and compiled through the existing release pipeline; exported packages load in legacy clients; richer existing packages retain behavior |

S1–S4 form the first usable release: one file, immediate local iteration and
reusable application colors. S5 adds visual authoring. S6 allows community
contributors to submit compact palettes without manually assembling a package.

For S6, add a documented flat `palettes/*.json` repository layout with publication
metadata, alongside existing `themes/*/theme.json` discovery. Reuse install
receipts, immutable release checks and rollback. Track source and compiler
versions in published digests; changes to either require a new compiled release.
Do not reinterpret an installed immutable release as an editable local source.

## Verification and completion

Extend existing focused tests rather than creating another desktop harness:

- Pure fixtures: minimal and fully explicit palettes, dark-only/light-only,
  Noctalia aliases, secondary-accent/text distinction, terminal preservation,
  malformed input, duplicate/conflicting keys and diagnostic paths.
- Discovery/service integration: missing-root creation, atomic save, deletion,
  rename, invalid-to-valid recovery, rapid edits, selection changes, unsaved draft
  races and restart from the retained valid snapshot.
- Renderer integration: shell/application equality for explicit roles, ANSI and
  Base16 projection, both variants, all 23 built-in targets subject to existing
  variant restrictions, unchanged user files on conflicts and disabled management.
- Compatibility: existing schema-1/2 packages, independent style choices, JSON CLI,
  community install/update/rollback and full fixed-render-data fixtures.

Run the affected existing build targets as each step lands: `test`,
`test-theme-packages`, `test-theme-discovery`, `test-matugen`,
`test-base-material-profiles`, `test-theme-github`, `test-theme-publishing`,
`test-custom-themes`, `test-theme-completion` and `test-preferences` as appropriate.
Use private XDG roots and compositor sessions for application/desktop acceptance.
All shipped implementation and author tooling stays in Zig.

Completion means a user with an installed Pearl binary can create a valid theme
from three colors in one file, select it, iterate without repackaging, reuse
enabled application templates, import a supported Noctalia palette and export a
publishable package. Preserve exact explicit colors, readable derived roles,
restart recovery and existing package compatibility. Record a clean-install
walkthrough and a second independently authored palette as acceptance evidence.
