# Custom Pearl themes

Status: implementation in progress, September 18, 2026. Native Zig package
validation, preferences/resolution, community HTTPS lifecycle, the Settings
browser, scoped CSS/imports, durable snapshots and the three theme test targets
exist. The implemented contract is in [CUSTOM_THEMES.md](CUSTOM_THEMES.md);
publishing is in [THEME_REPOSITORIES.md](THEME_REPOSITORIES.md).

T1–T3 have executable acceptance coverage. T4 includes bounded radii, borders,
padding, title scaling, shadows and motion; user font/density/motion settings
retain precedence. T5 includes restricted component CSS and package-local CSS
imports; image assets and a broader CSS contract remain open. Explicit previews
resolve built-in/fixed/generated colors in an isolated root; Matugen previews
are cancellable and have a deadline. Catalog refresh is explicit.
T6 remains dependent on the unimplemented Matugen profiles milestones M1–M5;
packages cannot yet declare application profiles or full render data. T7 author
and contributor docs and native validation/packing tools exist; default repository
hosting, maintainers and expanded visual/compatibility evidence remain open.
No official repository URL has been invented or automatically configured.

All deployed theme tooling is Zig. Python files are development test harnesses
only. The rest of this document records the target architecture and pending
acceptance, rather than claiming every milestone is complete.

## Intended behavior

Users browse a community repository in **Appearance → Pearl theme**, download
and install compatible packages, then select a theme. Community authors can
publish new themes without changes to Pearl's code or a new Pearl release.
Local folders and distribution packages remain supported installation sources.
Arc and Gruvbox were examples of the customization users expect, not required
outputs, bundled selections or a closed list of supported themes.

A theme can supply exact dark/light colors, widget styling and recommended
application profiles. Colors and styling remain independently selectable:

| Selection | Result |
| --- | --- |
| Community theme, theme colors, Pearl styling | The author's declared colors with Pearl's existing controls. |
| Community theme, wallpaper colors, theme styling | Matugen colors with the package's borders, corners and widget treatment. |
| Theme A styling, theme B colors | Styling and palette come from independently installed packages. |
| Installed GTK theme | Existing native GTK4 behavior, selected through the existing GTK controls. |

Selecting a package does not change wallpaper, application management switches,
manual application assignments or explicit font/density/motion preferences.
The draft previews proposed changes; Apply & save commits them across the shell
and Settings without restarting. Missing or broken packages remain visible with
an explanation and recovery choices.

Deliver local palette support as the foundation, then community distribution,
style customization and application profile integration. Community download and
installation are required for this feature to be complete. No milestone requires
reproducing a particular named third-party theme.

## Inspected starting points

- `src/config/preferences.zig` defines strict version-1 preferences and the
  `static`, `dynamic` and `gtk` theme modes. Static palettes are compiled in.
- `src/theme/theme.zig` defines 13 semantic color roles, palette validation and
  substitution into scoped CSS. Validation enforces hexadecimal colors and
  minimum contrast for selected text/background pairs.
- `src/theme/generator.zig` obtains a palette from Matugen using private
  configuration; it currently returns only Pearl's 13 roles.
- `resources/style.css` contains colors as placeholders but hardcodes most
  component radii, padding, borders and motion. `resources/gtk-theme.css`
  supplies the smaller native GTK layout layer.
- `src/config/service.zig` prepares appearance asynchronously, validates GTK
  providers before persistence, retains a working appearance on failure and
  reconciles external integration separately. Its current last-good JSON can
  still refer to missing external resources.
- `src/settings/preferences_view.zig`, `window.zig`, `editor.zig`,
  `backend.zig` and `editor_protocol.zig` own the Appearance controls, committed
  styling, shared drafts and frontend/backend boundary.
- QtEngine/Darkly, inline exports and Aqueous borders already consume Pearl
  palette roles. Their existing enablement and ownership behavior must persist.
- `src/lock/screen.zig` uses the preferences service. The greeter has separate
  administrator-owned configuration and does not import user preferences.
- The [Matugen profiles plan](MATUGEN_PROFILES_IMPLEMENTATION_PLAN.md) is also
  proposed. Its catalog, renderer and provider interface are dependencies for
  application-profile integration, not facilities assumed to exist today.

## Scope and architecture

Keep native GTK mode as its existing path. Pearl packages use Pearl's semantic
palette and component contract; GTK theme CSS is not automatically converted.
Existing GTK4-compatible themes continue to work through native GTK selection.

Use a pure resolver to combine preferences with a validated catalog into an
immutable `ResolvedTheme`: selected package IDs, asset digests, variant, shell
palette, style tokens, optional compiled stylesheet and provider snapshot.
The worker stages bytes; GTK provider creation remains on the GTK thread.
Every appearance consumer must use the same resolved revision instead of
independently selecting defaults or rereading changing package files.

Suggested implementation boundaries:

| File | Responsibility |
| --- | --- |
| `src/theme/package.zig` | Manifest types, bounded parsing, compatibility and palette validation. |
| `src/theme/catalog.zig` | XDG discovery, immutable asset snapshots, monitoring and catalog revisions. |
| `src/theme/repository.zig` | Community source configuration, versioned remote indexes, compatibility filtering and cached metadata. |
| `src/theme/install.zig` | Download, archive validation, staged installation, update/removal and installed-version receipts. |
| `src/theme/resolve.zig` | Package, palette, style and variant resolution; precedence and diagnostics. |
| `src/theme/style.zig` | Versioned style tokens, CSS generation and optional stylesheet validation. |
| `src/theme/theme_provider.zig` | Shared contract with the Matugen profiles feature; active package implementation. |
| `src/config/service.zig` | Prepare/validate/commit, appearance snapshots, recovery and integration scheduling. |
| `src/settings/*` | Installed/community browser, download/install status, preview API, independent overrides and committed styling. |

Add a theme-package installer; reuse the profiles plan's application adapters
and Matugen renderer for generated application files. Theme packages remain
declarative data. Community browsing, archive download and theme installation
are in scope. Automatic GTK conversion, user-theme greeter integration, paid
marketplace features and executing theme-supplied installation scripts are out
of scope.

## Package contract and discovery

Discover immediate package folders in `$XDG_DATA_HOME/pearl/themes` (normally
`~/.local/share/pearl/themes`) and each `$XDG_DATA_DIRS/pearl/themes`. The community
installer publishes validated folders into the user data directory. Manually
placed folders, local archive imports and distribution-installed packages use
the same manifest and resolver. Settings distinguishes installation origin and
provides Refresh; it does not require themes to appear in a built-in list.

Proposed layout:

```text
org.example.sample/
  theme.json
  palettes/dark.json
  palettes/light.json
  styles/default.json
  styles/extra.css             # optional, supported after the CSS milestone
  profiles/                   # optional Matugen profile manifests and assets
  LICENSE
```

Illustrative manifest, with optional styling and application features omitted:

```json
{
  "schema_version": 1,
  "id": "org.example.sample",
  "name": "Sample Theme",
  "author": "Example theme author",
  "license": "MIT",
  "source": "https://example.org/themes/sample",
  "asset_version": "1.0.0",
  "requires": { "palette_api": 1 },
  "palettes": {
    "dark": "palettes/dark.json",
    "light": "palettes/light.json"
  }
}
```

The name, license and source above are illustrative placeholders. Record actual
sources and preserve their notices for published community assets.
Each palette file contains all 13 existing `Palette` fields, using `#RRGGBB`.
Do not generate missing colors from a seed or silently fill missing roles.
Package authors explicitly map their colors to the semantic roles. Exact colors
means preserving these declared values; every role mapping must still meet
Pearl's contrast requirements.

Add optional `style` metadata with token/CSS paths and a `style_api` requirement,
plus `application_profiles` and `application_defaults` using the profiles
plan's descriptors. Capability requirements are explicit: a palette-only
implementation reports a style-requiring package as unsupported rather than
silently claiming to apply its complete appearance. Packages may be palette-only
or style-only; selecting an absent capability explicitly is a resolution error.

Reject duplicate IDs, unknown schema/API versions, duplicate JSON keys, invalid
identifiers, escaping paths/symlinks and unknown structural fields. Reserve
`pearl.*` IDs for built-ins. Invalid packages get catalog diagnostics without
preventing discovery of unrelated packages. Bound initial installed catalogs to
256 packages, manifests/palettes/token files to 64 KiB each, and the complete asset
snapshot to 16 MiB per package; document these limits and report exceeded limits.
Application assets also obey the renderer's tighter per-file limits.

Hash all referenced content, including CSS imports/assets and application
templates. Resolve references within the package root and capture validated
bytes before use, so file replacement cannot change an in-flight Apply.
Debounce directory/asset notifications; support explicit Refresh and avoid
recursive home scans or recurring idle polling. Catalog changes never silently
activate new package bytes. Show an update and require a new Apply; a stale
catalog revision invalidates an outstanding preview/Apply request.

## Community repository and package lifecycle

Define a versioned, host-independent repository index served over HTTPS. A
community Git repository can hold submissions and publish its index and release
archives through static hosting or release assets; Pearl consumes that format
without requiring Git, a hosting-provider account or provider-specific APIs.
Keep repository URLs configurable so additional community sources can be added
without rebuilding Pearl. Ship a maintained default community source once its
hosting and maintainers are established; its actual URL is a release setup task,
not an invented endpoint or dependency on a particular hosting service.

Each repository has a stable ID and display name. Each indexed release provides
package ID, version, author, license, project/source link, description, declared
capabilities and API requirements, supported variants, archive URL, compressed
size and SHA-256 digest. Optional screenshots have bounded dimensions/size and
their own URLs/digests. Use semantic package versions and immutable release
artifacts; a changed digest for an existing version is a repository conflict.
Verify index metadata against the downloaded manifest before installation.

The browser separates **Installed** and **Community** views with search, source,
variant and capability filters. Paginate the remote catalog independently of
the installed-package limit: at most 256 entries and 1 MiB per index page, with
bounded pagination/download work and cancellation. Newly published compatible
entries appear after Refresh without updating Pearl. Show unsupported packages
with their required capabilities and explain compatibility before download.
Repository metadata and screenshots are data, not executable HTML or scripts.

Store user-added source configuration in a separate backend-owned repository
document. Adding/removing a source is an explicit action and does not edit the
appearance draft. Pin a selected release to its repository identity, package ID,
version and digest. Never resolve equal package IDs from different repositories
using source order: show the collision and require a distinct package ID or an
explicit source replacement. Updates stay attached to the recorded source;
removing a source does not uninstall its packages or redirect their updates.

The backend owns a cancellable download/install job with progress and explicit
states: available, downloading, validating, installed, update available and
failed. HTTPS validates transport; the advertised digest detects archive mismatch
but is not independent proof of author identity. Display the repository and
author provenance accurately. Default-source maintainers review submissions and
control its index; user-added sources remain visibly distinct. Do not allow
archives to add repositories, run hooks or mutate application configuration.

Download one documented archive format initially, such as `.tar.gz`, into a
private staging directory. Enforce a 16 MiB compressed limit, the existing
16 MiB expanded snapshot limit, a 1,024-entry limit and bounded network
timeouts/redirects. Reject absolute/traversal paths, symlinks/hardlinks, special
files and duplicate archive paths before extraction can write them. Validate
the complete manifest, assets and supported APIs before atomic publication into
the user theme directory. Local archive import uses the same validation path.
Interrupted or failed downloads/installations leave the installed version intact.

Record installation receipts with source, version, digest and owned-file hashes.
Never overwrite a manually installed package or user-edited package as an update;
report the conflict. System packages remain managed by their distribution.
Serialize mutations per package and make recovery after interrupted publication
deterministic. A download/install operation does not select the theme, change the
shared draft or activate application profiles. Offer **Preview** and **Use theme**
after installation; selection is committed only through Apply & save.

Check for updates on explicit Refresh or opening the community browser using a
bounded metadata cache; do not add continuous polling. Updating installed bytes
keeps the currently committed snapshot running until a new Apply. Retain the
previous managed version for an explicit rollback, which likewise requires Apply
to change the active appearance. Uninstall only receipt-owned, unmodified user
packages; explain active theme/profile references first and retain the committed
recovery snapshot. Removed references become unavailable without substitution.

Network failures preserve the cached catalog with a stale/offline label, and all
installed themes continue to work offline. Support retry/cancel and expose errors
per source without hiding results from healthy sources. Theme activation and
session startup must not depend on network access.

Publish a contributor guide and repository validation workflow: authors submit
package metadata/assets, automated checks validate schema, archive contents,
palette/style contracts and attribution, then maintainers publish an indexed
immutable release. Include a local validation command so authors can test the
same rules before submission. Moderation and repository hosting are release
deliverables; ordinary theme additions must never require a Pearl code change.

## Preferences and resolution

Extend preference version 1 additively with a `package` mode and three bounded
IDs under `theme`: `package_id`, `palette_id` and `style_id`, defaulting to empty.
Retain `variant`, `source`, `seed`, `gtk_name` and `sync_borders` as they are.

```json
{
  "theme": {
    "mode": "package",
    "variant": "dark",
    "package_id": "org.example.theme-a",
    "palette_id": "org.example.theme-b",
    "style_id": "",
    "sync_borders": false
  }
}
```

Here theme A supplies styling/application defaults and theme B supplies the
explicit palette override. These IDs are examples of catalog entries, not
enumerated choices in the preferences schema. Resolution rules:

1. `package_id` establishes the active package and its application defaults.
   An empty ID means no package defaults. Merely overriding palette or style
   does not replace the active package's application recommendations.
2. `mode=static` keeps Pearl's compiled palette; `dynamic` uses Matugen seed or
   wallpaper colors; `package` uses `palette_id` when nonempty, otherwise the
   active package's palette. An absent palette in package mode is an error.
3. In non-GTK modes, explicit `style_id` wins. Otherwise use the active
   package's style if declared, then Pearl's built-in style. `pearl.default`
   explicitly selects Pearl styling while retaining a package's other defaults.
4. GTK mode uses native GTK providers and exposes no active Pearl package
   provider. Retain dormant package/palette/style IDs for switching back; their
   unavailability must not prevent applying an otherwise valid GTK selection.
5. Resolve only capabilities needed by the current selection. An explicit
   missing ID or unsupported variant is an error, not a silent substitution.
   Do not silently switch light/dark when a package supports only one variant.
6. Explicit user font, font size, density and reduced-motion preferences have
   final precedence over package styling. User GTK CSS keeps its existing
   highest priority. Document this precedence in the author guide.

The picker changes the active package in the shared draft and proposes package
colors. Preserve explicit overrides; provide a separate **Use theme defaults**
action that clears palette/style overrides. Label the effective choices so a
retained override cannot make a new package appear broken. Style-only packages
retain the current color source and cannot be selected as a palette source.

Old documents load unchanged. Old binaries reject the new enum/fields; document
switching to a legacy mode and removing the new fields before downgrading.
Avoid coupling dropdown indexes to enum values as the current form does.
Three-way merge continues to treat IDs as independent object fields.

## Palette and style implementation

Reuse and strengthen the existing palette validator: include error text pairs
and focus/control visibility in acceptance coverage. Keep normal text contrast
requirements; reject an invalid mapping with the offending roles and measured
ratio. Do not silently recolor a fixed palette. Generic palette fixtures must
use a documented accessible role mapping and verify preservation of exact values.

Replace fixed values in `resources/style.css` with typed style tokens in stages.
Start with component corner radii, border widths, horizontal/vertical padding,
typography scale, shadows and motion durations. Defaults must reproduce the
current appearance. Use bounded numbers and structured shadow/font values;
never interpolate unvalidated CSS text as a token. Audit widget-set margins,
spacing and minimum sizes as well as CSS: expose supported values or explicitly
document fixed layout constraints. Token changes must preserve native input
regions, popup placement, bar reservations and dock hit targets.

Treat the optional CSS layer as a separate delivery milestone. Publish stable
Pearl component classes, interaction states and a `style_api` version before
encouraging third-party styles. Permit palette-role references so a style can
follow wallpaper colors. Authors may use literal colors, but previews must
make their effect apparent; such a style need not recolor completely.

Validate selectors and imports structurally, using a documented supported CSS
subset; do not prefix arbitrary CSS with a regular expression. Require each
selector branch to stay under the assigned Pearl theme root. Reject unsupported
at-rules, global selectors, remote URLs, import cycles and references escaping
the package. Set bounds on import depth, bytes and decoded asset dimensions.
Parse the completed stylesheet with GTK before commit. Keep a built-in layout
and focus/accessibility layer, while documenting that arbitrary permitted CSS
still requires visual review and cannot have its contrast proven from palette
validation alone. If a reliable validator is not ready, ship tokens without CSS
and keep the full-style milestone open.

The lock screen consumes validated colors and a restricted set of safe tokens
with built-in authentication layout/focus styling; package CSS is not applied
to authentication surfaces. Test that a broken shell style cannot hide unlock
controls. The greeter continues to use administrator configuration separately.

## Apply, snapshots and recovery

Extend the existing prepare → GTK validation → persistence → publish flow.
Prepare an immutable appearance snapshot from the exact package digests and
preference/catalog revisions captured by the draft. Cache by palette input,
variant, style/asset digests, renderer versions and explicit user overrides.
A style-only update must invalidate CSS even if Matugen's palette cache hits.
Cancel obsolete work; an older job must never publish after a newer selection.

Persist validated package assets needed for the committed appearance in a
bounded, content-addressed last-good store under Pearl's configuration/state
ownership. Write the snapshot before publishing its durable reference; clean
up only unreferenced snapshots after a successful commit. Store preferences
and snapshot identity together in recovery metadata so restart cannot mix
different revisions. Do not rely on a mutable installed folder or a disposable
cache for recovery. Test interruption between each persistence step.

On runtime package deletion/corruption, keep the current snapshot and mark the
selection unavailable. A failed requested Apply preserves the draft, saved
preferences and appearance. At restart, recover the committed snapshot; if it
is unavailable or incompatible with the running style API, use built-in styling
and report recovery without silently rewriting the user's requested selection.
Provide **Use built-in theme** as a reachable recovery action in Settings/CLI.

Supply Settings with the committed resolved appearance through bounded backend
snapshots, including validated assets needed to render it. Do not have the
frontend independently execute Matugen or resolve changed package folders.
Draft previews use isolated widget roots and snapshot revisions, leave the
main Settings appearance committed, and never write application files. Palette
generation for an explicit preview is cancellable; browsing catalog metadata
does not launch generators.

## Application profiles, Qt and borders

Implement the provider stub from the Matugen profiles plan using the committed
active package. Publish its digest/revision, profile descriptors and default
application assignments. Manual selections and Off always retain precedence;
the master application-management switch remains opt-in. Palette/style
overrides do not silently change these assignments. Keep independently chosen
profiles discoverable from installed packages even when their package is not
active; removal makes them unavailable without substituting another profile.

Extend the provider contract with optional versioned application render data.
Pearl's 13 shell colors alone cannot satisfy all Matugen templates. Define and
verify a complete role mapping/serialization against the installed supported
Matugen version before accepting package-supplied render data. Preserve exact
declared colors through rendering; do not regenerate a fixed palette from a seed
and claim to preserve the author's colors. Missing required render roles
produce a per-profile unsupported status and preserve its previous output.

For application colors set to Follow Pearl, dynamic mode uses the complete
generated palette. Package mode uses compatible full render data from the
effective palette package, including `palette_id` overrides. Static/GTK or a
shell-only palette reports no complete render palette, as in the profiles plan.
Independent application seed/wallpaper sources continue to work in every shell
mode. The application renderer must declare/check the render-data contract it
needs; shell palette support does not imply application-template compatibility.

Application reconciliation follows shell commit and reports desired/applied
revisions separately. Its failure does not undo a valid shell theme. Reuse the
profiles plan's adapters, journals, ownership checks and restoration behavior.

Qt Follow Pearl, inline exports and enabled border synchronization can consume
custom shell palettes through their existing role mappings. Explicit static Qt
choices remain static. GTK fallback and border pause behavior remain unchanged.
Pearl widget CSS does not style Qt: QtEngine/Darkly stays the sole Qt settings
writer; additional Qt widget styles would need separate style support.

## Settings, documentation and fixtures

Add the installed/community browser described above, including source management,
download/install/update/remove actions and progress. The package picker shows
installed/unsupported/unavailable states, author/source attribution, supported
variants and a small component preview.
Show separate **Colors** and **Widget style** controls plus **Use theme defaults**.
Keep the native GTK path accessible. The application card shows which active
package supplied an inherited profile and whether application colors can follow
the effective palette. Preserve shared draft Apply/Discard/conflict behavior.

Extend the backend protocol with capability negotiation, bounded catalog and
appearance transfers, revision-checked preview/refresh/apply, repository actions,
install-job progress/cancellation and actionable diagnostics. Capture the exact
release identity/digest in each install request and reject stale metadata instead
of installing a different release. Older clients must fail clearly on unsupported
theme operations. Keep network access, file discovery, installation, validation,
generation and persistence in the backend.

Ship a minimal author example and generic palette/style fixtures, plus a fixture
community index and release archives. Use arbitrary IDs and publish an additional
fixture theme during acceptance to prove there is no hardcoded selection list.
Named themes such as Arc or Gruvbox may be contributed like any other compatible
package; they are not required built-ins or release acceptance targets. Record
source, license, color mapping and locally authored changes. Update preferences,
frontend API, packaging and development docs, plus versioned theme-author and
community-repository contributor guides.

## Delivery sequence and acceptance

| Milestone | Deliverable | Completion check |
| --- | --- | --- |
| T1: contracts and fixtures | Package/index schemas, repository identity, palette mapping, limits, preference/resolver contract and generic fixtures. | Old preferences resolve identically; invalid packages/indexes, duplicate IDs/keys, incompatible versions, escaping paths and unavailable variants produce specific errors. |
| T2: local palette foundation | Catalog, immutable snapshots, package palette mode, basic Appearance picker and recovery. | Install/select an arbitrary fixture without Matugen; exact role values reach shell/Settings; Apply/Discard/merge and missing-package restart recovery work in private XDG directories. |
| T3: community distribution | Source management, browser/search, index cache, downloads, local archive import, receipts, updates/removal and author validation command. | Publish a previously unknown package to a fixture repository, Refresh, download, install, preview and Apply without rebuilding Pearl; verify source conflicts, failed downloads, update/rollback, edited files, uninstall and offline operation. |
| T4: independent styling | Style tokens, palette/style overrides, stable component contract and full preview controls. | Independently downloaded styles combine with another package's colors and dynamic colors; defaults match baseline; font/density/motion overrides and window/input geometry remain correct. |
| T5: advanced styles | Scoped CSS subset, local assets/imports, validator and restricted lock styling. | Representative community-style CSS renders; malformed/out-of-scope CSS, escaping assets and oversized resources reject before save; lock controls stay usable. |
| T6: application provider | Real provider, complete fixed render data and profile inheritance. | With profiles-plan M1–M5 available, inherited assignments update, manual/Off persist, palette overrides supply the correct data, and shell-only palettes report unsupported rendering without damaging outputs. |
| T7: release and community publishing | Author/API/contributor docs, default repository hosting and maintainers, publishing checks, compatibility evidence and downgrade/recovery instructions. | The configured community source serves validated releases; a contributor can publish a new theme without a Pearl release; required suites pass and remaining application activation steps are documented. |

T2 is a foundation, not completion of the requested community-theme feature.
T3 depends on T1/T2 and provides its first usable download/install workflow.
T4 depends on T2 and uses T3 for community acceptance; T5 depends on the T4 style
contract. T6 depends on T2 and the application-profiles milestones but does not
need T5. T7 completes release setup. Do not mark community distribution, advanced
styles or application integration complete when only local palette packages ship.

Introduce `test-theme-packages` for parser/resolver/discovery/recovery tests and
`test-theme-repository` for remote indexes and download/install lifecycle, and
`test-custom-themes` for private-session rendering and live-apply acceptance.
These names are proposed targets. Use a private fixture server and archives for
network tests, including invalid digests, metadata/manifest mismatches, malformed
archives, interruption, timeouts, redirects, stale indexes, pagination and offline
cache fallback. Cover package updates during preview/Apply,
simultaneous preference changes, cancellation, partial installs, duplicate
catalog entries, deletion/reinstallation, stale snapshots and interrupted saves.
Verify no generator starts for a fixed palette and no recurring idle work is
introduced by package discovery.

Run existing `test`, `test-preferences`, `test-settings-appearance` and
`test-settings-boundary` for schema/backend work. Run `test-components`,
`test-settings-presentation` and `test-lock` for styling work; run
`test-border-theme`, `test-qt-theme-unit` and the applicable Qt integration
checks when those consumers change. T6 also runs the profiles plan's proposed
`test-matugen` suite. Use the isolated environments in
[DEVELOPMENT.md](DEVELOPMENT.md), with private XDG roots, compositor and bus.

Visual acceptance covers light/dark, compact/normal, increased text size,
reduced motion, keyboard focus, disabled/error states, narrow windows, multiple
outputs and output removal. Inspect the bar, dock, launcher, popups, Settings,
notifications and lock screen. Keep rendered evidence and exact fixture/version
identities together; do not change the user's live theme for acceptance tests.
