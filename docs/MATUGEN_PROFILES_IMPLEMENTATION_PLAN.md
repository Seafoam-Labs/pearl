# Individual Matugen application themes

Follow-up: [automatic wallpaper-driven updates](MATUGEN_WALLPAPER_LIVE_UPDATE_PLAN.md)
plans image watching, refreshed color inputs and generation-aware application.

Status: implemented locally with focused acceptance, September 18, 2026.
The Zig catalog/provider, complete Matugen JSON inputs, worker, adapter journals,
committed snapshots and shared Settings controls now exist. M1–M6 remain subject
to the expanded acceptance/release gates in the [completion plan](CUSTOM_THEMES_COMPLETION_PLAN.md).
The architecture below records the intended behavior, not a claim that every
manual application activation/accessibility scenario has been certified.

See [current contract and recovery](CUSTOM_THEMES.md) and
[execution evidence](../artifacts/theme-completion/README.md). Five attributed
Seafoam profiles are installed as data; Zed and Starship’s DMS-only terminal roles
were explicitly ported to Matugen base16 (mapping in themes/profiles/ATTRIBUTION.md).
The real package provider and fixed full render data are implemented. The default
GitHub repository remains uncreated/unpublished and disabled in Pearl builds.

## Intended behavior

Add **Appearance → Application themes → Matugen profiles**. Users can select a
profile for each application independently of their Pearl shell theme. Pearl
theme packages will provide profiles and recommended assignments through a small
provider interface. Establish the interface with fixture providers first, then
connect the real committed package provider as required by completion step C4.
An empty provider is a development stage, not completion of theme inheritance.

Each application has three choices:

| Selection | Effective behavior |
| --- | --- |
| Follow Pearl theme | Use the active theme's assignment for this application, if provided; otherwise leave it unmanaged. |
| Choose profile | Use the explicitly selected compatible profile, regardless of the active Pearl theme. |
| Off | Do not generate, install or reload this application's theme, including when a Pearl theme supplies one. |

A master **Enable application themes** switch defaults off. Missing application
entries default to Follow Pearl theme, but have no effect while management is
off. Explicit selections and Off survive theme changes. Switching back to Follow
retains the last manual choice for convenient reselection. Expose the resolved
profile and its origin: “Seafoam Labs · chosen individually” or “From Pearl theme”.

Selecting a profile chooses an application's styling template; it does not
implicitly select the Seafoam shell palette or change the current shell theme.

## Inspected starting points

- Pearl `src/config/preferences.zig` has strict version-1 preferences, three
  shell modes (`static`, `dynamic`, `gtk`) and an eight-item inline export list.
- `src/theme/generator.zig` obtains palettes with Matugen 4.x, an empty private
  configuration and `--dry-run`. `src/theme/theme.zig` reduces the result to 13
  shell roles. These roles are insufficient for the supplied application templates.
- `src/config/service.zig` implements exports with simple `{{role}}` substitution
  and ownership hashes. Its Qt integration already provides a model for separate
  desired/applied revisions, conflict reporting and conditional restoration.
- The standalone Settings form lives in `src/settings/preferences_view.zig`;
  `editor.zig`, `backend.zig` and `editor_protocol.zig` coordinate drafts and
  backend-owned mutations. The frontend must continue to avoid direct file writes.
- DMS's inspected local revision is `72ca8a6876b014f5722a00f69301a5766653764e`.
  Its [settings form](https://github.com/AvengeMedia/DankMaterialShell/blob/72ca8a6876b014f5722a00f69301a5766653764e/quickshell/Modules/Settings/ThemeColorsTab.qml)
  separates user templates from DMS templates and provides per-application
  controls. Its [registry and generator](https://github.com/AvengeMedia/DankMaterialShell/blob/72ca8a6876b014f5722a00f69301a5766653764e/core/internal/matugen/matugen.go)
  track application detection, template selection and reload behavior. Use this
  interaction model, extending it with named profiles and theme inheritance.

The referenced [aqueous-dotfiles repository](https://github.com/Seafoam-Labs/aqueous-dotfiles/tree/76772cb9d009f971193b6fb2dbb56854055225d5)
was inspected at `76772cb9d009f971193b6fb2dbb56854055225d5`.
Its [Matugen configuration](https://github.com/Seafoam-Labs/aqueous-dotfiles/blob/76772cb9d009f971193b6fb2dbb56854055225d5/etc/skel/.config/matugen/config.toml)
declares these targets:

| Target | Supplied template | Initial Pearl treatment |
| --- | --- | --- |
| Equibop | `discord.css` | Independently selectable Midnight profile; note its dark-mode requirement. |
| Fluxer | `fluxer.css` | Independently selectable profile; expose generated CSS and application setup instructions. |
| Starship | `starship.toml` | Full prompt configuration; offer an explicit managed installation, never silently replace an existing prompt. |
| Steam | `steam.css` | Generate CSS for AdwSteamGtk; show installation instructions initially. |
| Zed | `zed-colors.json` | Install a Pearl-named theme file; let the user activate it in Zed. Contains both light and dark themes. |
| Aqueous settings | external `dms.json.in` | Show unavailable unless the referenced asset exists and its adapter is validated; do not invent a bundled template. |

The Starship `output_path` lacks its closing quote in the inspected TOML. Steam
declares `post_hook = 'adwaita-steam-gtk -i'`. Import template assets through
explicit manifests; do not execute or concatenate this configuration. The
[Seafoam DMS theme](https://github.com/Seafoam-Labs/aqueous-dotfiles/blob/76772cb9d009f971193b6fb2dbb56854055225d5/etc/skel/.config/DankMaterialShell/themes/seafoam/theme.json)
is a separate dark/light palette with `scheme-expressive`, not a Pearl provider
manifest or a set of fixed-color application themes.

## Preferences and resolution

Add an optional `matugen` object to preference version 1, consistent with the
existing additive Qt integration. Old documents load with management disabled;
older binaries reject this new field under their strict parser. Document removing
the object after disabling/restoring management before a downgrade.

Illustrative persisted state:

```json
{
  "matugen": {
    "enabled": true,
    "colors": { "source": "follow_pearl", "seed": "#2dd4a8" },
    "applications": {
      "zed": { "mode": "profile", "profile_id": "seafoam.zed" },
      "equibop": { "mode": "theme", "profile_id": "" },
      "steam": { "mode": "off", "profile_id": "seafoam.steam" }
    }
  }
}
```

Use a bounded application-ID map so edits to different applications can merge
through the existing object merge semantics. Limit it to 32 applications; IDs
are bounded identifiers, not paths. Reject duplicate/unknown structural fields,
invalid modes and application/profile mismatches. A `profile_id` is required in
profile mode and ignored, but retained, in other modes. A removed profile is a
resolution error, not malformed preferences: keep the selection visible and do
not silently substitute another profile. Apply the same rule to a broken theme
assignment. An absent theme assignment means unmanaged, without an error.

Keep persisted intent separate from resolved status. A pure resolver accepts the
preferences, catalog and active provider and returns one effective assignment per
application. Disabled management wins first, then application Off/manual choice,
then the theme assignment. Duplicate writers for the same destination are a
conflict, never a last-writer-wins rule.

Theme changes recompute inherited assignments only. Explicit profile IDs remain
stable even when their provider disappears; report unavailable and preserve the
last installed output until the user chooses another profile or restores it.

## Profile catalog and theme-provider interface

Introduce `src/theme/matugen_profiles.zig` for typed metadata, validation and
resolution, plus `src/theme/theme_provider.zig` for the narrow provider contract:

```text
ThemeProviderSnapshot {
    theme_id?, revision,
    profiles[],                    // same descriptors used by the independent catalog
    defaults: application_id -> profile_id
}
activeThemeProvider() -> snapshot  // fixtures first, committed package provider in C4
```

The provider must not infer a Pearl theme from `gtk_name` or the DMS settings file.
Use fixtures to prove theme inheritance before connecting the real provider.
Show “This theme provides no profile” only when the committed provider has no
assignment. Completion step C4 connects the existing package system to this
interface; the profile model does not need a second store or downloader.

A profile descriptor contains schema version, namespaced ID, application ID,
display name, author/source attribution, asset version/digest, template paths,
supported variants, output filenames, an adapter ID and setup instructions.
Support multiple profiles per application and multiple files per profile. Keep
origin (Seafoam collection, local profile, Pearl theme) as metadata rather than
requiring the entire collection to be selected together.

Discover system profiles under XDG data directories at `pearl/matugen/profiles`
and user profiles under `$XDG_DATA_HOME/pearl/matugen/profiles`. Reject ambiguous
duplicate IDs instead of silently shadowing installed profiles. Resolve assets
relative to their manifest root, rejecting traversal and escaping symlinks.
Manifests declare known adapters, never arbitrary destination paths or commands.
Use explicit refresh and changes to known catalog directories; no recursive home
scan or recurring polling. Catalog content changes advance a revision used by
Apply so an old draft cannot install different bytes unnoticed.

Ship the five available Seafoam profiles as a separately attributed data
collection. Preserve upstream notices and record the pinned source and local
fixes; check individual template provenance before redistribution. Keep fixtures
small, with real complete templates used in renderer integration tests.

## Color inputs and rendering

Keep profile selection independent of color selection. Initially expose one
application color source shared by selected profiles:

| Color source | Behavior |
| --- | --- |
| Follow Pearl | Reuse the complete generated palette in dynamic mode. In static/GTK mode report no complete Matugen palette and retain outputs. |
| Seed color | Generate application colors from the configured seed without changing Pearl's appearance. |
| Wallpaper | Generate application colors from Pearl's validated wallpaper snapshot independently of the shell mode. |

Use Pearl's committed dark/light variant. If a selected profile is dark-only,
show it as unsupported in light mode and retain its prior output rather than
quietly applying dark styling. A future provider may supply a complete render
palette through a later contract extension; the initial stub does not claim
exact Seafoam palette reproduction. Independent seed/wallpaper sources make
application profiles usable even with static or GTK shell themes.

Retain Matugen's complete dark/light render data, including the roles and RGB
components used by the upstream templates; derive Pearl's small palette from
the same generation. Use Matugen itself for template rendering rather than
extending the existing export string replacer into a second template engine.
The installed CLI exposes `matugen json <PATH>`; M1 must verify its exact round
trip with both variants before choosing the on-disk palette serialization.

Render with an explicit Pearl-generated TOML config into a private per-job
staging directory. Only selected validated templates appear in it. Do not pass
the user's global Matugen configuration, hooks or wallpaper actions. Rendering
must omit `--dry-run` because that suppresses template outputs; palette extraction
continues to use it. Run subprocesses with argv, cancellation, bounded output and
deadlines, extending the existing generator worker. Bound asset/output reads
separately from subprocess stdout; the supplied CSS exceeds inline-export needs.

Cache by complete color input, generator/adapter versions, variant, selected
profile IDs and asset digests. A profile-only change must rerender even when the
shell palette is unchanged. Coalesce obsolete work and prevent an old revision
from publishing after a newer Apply. No generator remains running at idle.

## Installation, ownership and status

Publish generated files under `$XDG_CONFIG_HOME/pearl/matugen/outputs/<application>/output-N.ext` (fixed adapter directories bound storage across arbitrary profile IDs).
Application adapters copy or reference those files only at defined destinations:

- Zed and Equibop: install distinct Pearl-owned theme files in their theme
  directories; document activation in each app.
- Fluxer and Steam: generate ready-to-use CSS and show the consumer's manual
  activation steps. Steam's upstream install hook is not automatically run.
- Starship: start with generated output and setup instructions. Provide a
  separate explicit install action with a concrete diff for replacing the full
  prompt configuration; preserve an original snapshot and detect user edits.

Selection and installation are separate status facts: “Generated; activation
required” is not “Applied”. Application detection is informational and must not
prevent generating a profile for an app installed later. Initial native adapters
do not claim Flatpak support without verifying its configuration paths.

Reuse the ownership and recovery patterns in `src/config/qt_integration.zig`:
account-wide writer lease, bounded journal, previous bytes/absence, hashes of
owned outputs and conditional restoration. Avoid a broad Qt refactor. Preflight
all files for one application, stage them, then commit with recoverable journal
steps; do not claim atomicity across unrelated filesystem locations. Preserve
user changes and show conflicts instead of overwriting them.

Off stops generation and reloads immediately and restores/removes only installed
files still owned by Pearl. Generated standalone output can remain on disk.
When switching profiles, restore obsolete owned destinations through the same
journal. Never remove or modify a user-edited file as cleanup. Missing providers,
missing Matugen, invalid templates and unsupported variants retain last-good
outputs with actionable per-application status.

Reconcile application outputs after preference commit, like Qt integration.
Report application failures separately from the successful shell preference
save. Track desired/applied revisions and per-target states: unmanaged, pending,
generated, activation-required, applied, unavailable, unsupported, conflict and
failed. Retry acts on the committed selection. Reload only an enabled application
whose output changed and whose built-in adapter explicitly supports it; never
run profile-supplied shell hooks.

Existing inline `exports` remain compatible. Do not route profiles through their
eight-template/8192-byte limits. QtEngine/Darkly remains the sole Qt settings
writer; new profiles cannot bypass that ownership model.

## Settings and backend changes

Add the application card to `src/settings/preferences_view.zig` (or extract a
focused view if its size warrants it). Include the master switch, color source,
application search, per-application selection, profile picker, resolved origin,
availability and activation instructions. Keep unavailable saved selections
visible. Add “Reset to theme” per application. Catalog inspection and draft
editing must not generate outputs or install files.

Extend `src/settings/backend.zig`, `editor_protocol.zig` and the existing editor
dispatch with bounded catalog/status snapshots and revision-checked retry,
installation review and restore actions. Advertise capability availability so
older frontends/backends fail clearly. Use existing document transfer limits for
larger catalogs rather than increasing the small CLI status frame unboundedly.
The standalone application retains the current shared draft, Apply, Discard and
three-way merge behavior; all filesystem work belongs to the backend worker and
obeys existing session/lock gates. Surface a compact summary in CLI status.

## Delivery sequence and acceptance

| Step | Deliverable | Completion check |
| --- | --- | --- |
| M1: compatibility fixtures | Pin the five templates, record attribution and correct manifest paths; prove complete palette extraction and Matugen JSON rendering. | All five render from a fixed seed; Zed parses with both variants; Starship parses as TOML; CSS has no unresolved template tokens; no global config or hooks run. Record dark-only behavior separately. |
| M2: model and resolver | Preferences, catalog, profile descriptors and empty theme provider with fixture providers. | Test Off/manual/inherit precedence, no-provider fallback, provider changes, missing IDs, duplicate destinations, old preferences and invalid manifests. |
| M3: render worker | Full palette retention, independent color source, staging, cache, cancellation and stale-revision protection. | Same input reuses cache; changed template invalidates it; seed/wallpaper profiles work with a GTK shell; failures retain outputs; no idle subprocess/timer work is introduced. |
| M4: application adapters | Generated outputs, native Zed/Equibop installation, other setup flows, ownership journals and Starship review. | Isolated XDG tests cover fresh install, profile switch, Off/restore, user edits, interrupted writes, writer contention and unchanged-output reload suppression. |
| M5: Settings and API | Draft controls, catalog/status, error recovery and capability negotiation. | Select only Zed while Steam is Off; Apply/Discard/merge work; inherited changes never replace a manual choice; activation-required states are truthful; keyboard navigation works. |
| M6: release documentation | Package collection and manifests, update preferences/frontend API docs, add consumer setup and downgrade instructions. | Run focused unit/integration suites and isolated real-app checks; record supported versions and manual-activation gaps. |

M1 and M2 establish the contracts before M3/M4; M5 consumes those contracts.
All six steps deliver individual selection. Fixture providers establish resolver
and UI coverage; full theme inheritance additionally requires the committed
package provider and immutable render inputs in completion step C4. The package
foundation already exists, but that integration remains unimplemented.

Add a focused `test-matugen` target for meaningful resolver, renderer and ownership
tests. Also run the existing preferences and Settings suites when their schemas
or draft flow change, and Qt regression checks if shared reconciliation code is
touched. Use the isolated environments in [DEVELOPMENT.md](DEVELOPMENT.md), never
the live user's application configuration for acceptance tests.
