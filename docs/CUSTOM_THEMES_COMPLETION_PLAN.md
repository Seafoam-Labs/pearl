# Finish community themes

Status: local implementation and focused verification, September 18, 2026.
C1–C4 are implemented in Zig; C5 has native publication/verification tools and a
[reviewable repository scaffold](../community-repository/README.md). The hosted
default remains disabled. [Evidence and outstanding gates](../artifacts/theme-completion/README.md)
distinguish tested behavior from the remaining launch/manual acceptance work.
The current contract is [Community themes](CUSTOM_THEMES.md).

The default community project will be **Seafoam-Labs/pearl-community-themes**
on GitHub. The repository does not exist yet. Creating it, publishing its first
releases and enabling the default source are explicit delivery steps below.
Arc and Gruvbox remain examples, not required packages or hardcoded selections.

All new Pearl tools, validators, repository generators and runtime integration
must be Zig. Existing native libraries and the Matugen executable may be used;
do not deploy Python scripts or introduce Python publishing tools. Python may
remain in development-only integration tests. Workflow YAML invokes Zig tools.

## Starting point and completion criteria

| Area | Implemented foundation | Remaining deliverable |
| --- | --- | --- |
| Packages and styling | Strict schema 1, exact palettes, typed tokens, scoped CSS and local imports | Validated static images, durable asset bundles and frontend transport |
| Discovery | Bounded XDG scans and explicit refresh | Event-driven updates, stale-draft handling and monitor failure reporting |
| Applications | Shell palette generation, Qt/border integration and inline exports | Profile catalog, complete render data, renderer, adapters, ownership recovery, Settings and real package provider |
| Distribution | HTTPS indexes, native pack/validate/install, receipts, rollback and configurable sources | GitHub project, review/publishing pipeline and default-source migration |

Completion means an author can submit an arbitrary new package with images and
application profiles, publish it to the default repository, and a user can
download, preview and apply it without a Pearl rebuild. Local package changes
appear automatically, while activation still requires Apply. Application
management stays opt-in and each application can follow the theme, choose an
independent profile or remain Off. Restart and offline operation retain the
exact committed appearance and application inputs.

The existing evidence is in [artifacts/custom-themes](../artifacts/custom-themes/README.md).
It covers the foundation, not these remaining features. Its failed monitor-removal
presentation check remains a release acceptance issue to reproduce and resolve.

## C1 — Version the contracts and prove the rendering paths

Work in `src/theme/package_model.zig`, `package.zig`, `resolve.zig`,
`repository.zig`, `commands.zig`, `src/settings/editor_protocol.zig` and the
author/repository guides before implementing consumers.

- Keep existing schema-1 packages and indexes readable with unchanged behavior.
  Introduce package schema 2 for image declarations, application profile
  descriptors/defaults and optional full render data. Give image styling
  `style_api: 2`; preserve `palette_api: 1` for the existing 13 shell roles.
  Add independent, versioned profile and render-data capabilities; a package
  must declare only the capabilities it uses. Unknown fields remain errors.
- Introduce index schema 2 to advertise the new requirements. Preserve the
  current 16-release/96,000-byte page and 1 MiB download bounds. Teach new clients
  both index versions; old clients receive an explicit unsupported-schema error,
  never a partially understood install. Schema-1 repositories continue to work.
- Define logical asset IDs mapped to package-relative paths, profile IDs mapped
  to descriptors/templates, per-application defaults and per-variant render-data
  paths. Resolve references from the captured package bytes with existing
  no-link/path/depth rules. Include every referenced byte and contract version in
  the relevant digest. Reject missing defaults, duplicate profile IDs and unknown
  application adapters. No package field specifies a command or arbitrary output
  destination. Existing manifest `asset_version` remains the package version.
- Prototype a GTK image provider usable by the shell, committed Settings and an
  isolated preview. Use validated bytes in an in-memory GResource with a
  digest-qualified namespace, built/registered by native code. Prove CSS lookup,
  provider lifetime and resource release before freezing the asset contract.
  Do not rely on mutable package filenames or invoke an external asset compiler
  at runtime. Register only Pearl-built resource containers, not supplied blobs.
- Complete profiles-plan M1's Matugen extraction/JSON-input round trip with the
  supported Matugen version. Record complete required roles, color formats,
  variant handling and renderer version compatibility in fixtures. Do not design
  fixed render data around the 13-role shell projection alone.

Acceptance: schema-1 fixtures retain their results; schema-2 compatibility and
unknown-field tests pass; an original PNG appears identically in shell/Settings/
preview with distinct lifetimes; full fixed palette data round-trips without
seed regeneration or user Matugen configuration/hooks.

## C2 — Image assets from validation through recovery

Add focused Zig asset validation/provider modules under `src/theme`; extend
`style.zig`, `package.zig`, `resolve.zig`, `snapshots.zig`,
`src/config/service.zig`, Settings appearance transfer and `themes_view.zig`.

### Supported author contract

Start with **static PNG** for decorative component backgrounds. Support a
structurally parsed `url("theme-asset:<id>")` value on explicitly permitted
component `background-image` declarations, plus a small documented set of
position/size/repeat values. The compiler substitutes its own resource URI.
Reject arbitrary URLs, SVG, animation, filesystem paths, remote imports and
unrecognized CSS. Broader image formats and global GTK styling are outside this
delivery. Images cannot replace authentication controls, focus indicators or
application icons. Preserve user font, density and reduced-motion precedence.

Initial enforced limits: at most 32 declared images, 2 MiB encoded per image,
8 MiB encoded images per resolved appearance, 2,048 pixels per dimension and
32 MiB total decoded RGBA pixels per resolved appearance. Enforce combined limits
across independently selected packages, not just each package separately.
The existing 16 MiB package and 1,024-entry limits still apply. Reject excessive
dimensions before allocation, validate the complete PNG with a bounded native
decoder, reject APNG control chunks, and reject truncated or inconsistent data.
Set decoded-memory and concurrency limits for validation and preview jobs;
header checks alone are not validation. Catalogs retain metadata, not textures.

### Persistence and frontend boundary

Extend the immutable resolved snapshot with an asset manifest containing logical
IDs, hashes, sizes, dimensions and normalized validated image bytes. Keep large
blobs outside the existing 16 KiB snapshot JSON. Version snapshot metadata and
continue reading existing asset-free snapshots.

Persist content-addressed blobs and their manifest before the preferences/snapshot
reference commits. Fsync through the existing durability path, then publish the
GTK provider. Failure at any stage retains the prior appearance and preferences.
Restart verifies referenced bytes and restores the exact appearance even after
package removal or an update. Corrupt/missing blobs trigger the existing explicit
recovery state; do not silently load a newer installed package.

Replace file-count-only retention with reference-aware collection. Keep blobs
reachable from current, previous and retained history snapshots, and pin resources
for live previews/committed providers. Add a 256 MiB durable asset-store ceiling;
check space before commit and report capacity failure without deleting protected
snapshots. Prune unreferenced owned blobs after successful commits and clean
abandoned staging data on recovery. Bound unsuccessful writes as well as history.

Negotiate an asset-transfer capability. Keep the existing 120,000-byte theme
response limit: send metadata and revision-bound asset handles, then bounded
chunks of at most 48 KiB before encoding. Authorize handles for the requesting
session and exact snapshot; do not accept paths. Check total length/hash before
resource registration, cap outstanding requests and cancel obsolete transfers.
The frontend renders received bytes in memory; it does not discover packages,
read their files or launch generators. Keep its current appearance until the
complete new provider is ready. Older clients report unsupported image styling.

Acceptance: valid transparent images render in dark/light and combined styles;
bad dimensions, bombs, animations, traversal, missing IDs and malformed CSS fail
before save. Test edits during decode/preview/Apply, cancellation, chunk corruption,
disconnect, crash boundaries, shared-blob retention and quota exhaustion. Package
deletion followed by restart preserves the image. Lock/greeter authentication
surfaces retain built-in styling. Visual review must include text contrast over
images; palette contrast checks alone do not establish that.

## C3 — Automatic local discovery

Add `src/theme/discovery.zig` and a backend-owned catalog coordinator. Reuse the
bounded GIO monitor patterns from `src/plugins/discovery.zig`, but do not inherit
its recurring fallback polling. Continue using `catalog.zig` as the validation
and content-revision authority.

1. Scan once at startup. Monitor known user/system theme roots, package
   directories and nested asset/template/import directories within existing
   depth and entry bounds. Monitor the nearest existing ancestor when a root is
   missing, filtering events to that root. Add independent profile roots when C4
   lands. Never recursively scan the user's home or follow symlinks.
2. Coalesce event bursts with a 200 ms debounce and a one-second maximum delay.
   Allow one scan worker and one pending rescan; obsolete generations cannot
   publish. Install/update/rollback/remove enqueue the same coordinator after
   publication. Ignore private staging and receipt/journal paths.
3. Rebuild watches after creation, rename, root replacement or removal. Bound the
   set to 4,096 directory watches. On watch exhaustion/failure report degraded
   discovery with an explicit Refresh action. On reported monitor loss, perform
   one bounded rescan/rebuild; persistent failure must not create a busy loop.
   Do no periodic work when idle. Test rescan races while watches are changing.
4. Publish a catalog generation/change notification, with diagnostics included
   in its identity even when valid package bytes are unchanged. Keep the package
   content revision used by Apply separate from this notification generation.
   A newly invalid package or repaired duplicate must visibly update Settings.
5. Refresh metadata automatically in connected Settings, preserving selections,
   search and the shared draft. Mark affected selections/previews stale. Do not
   silently replace the draft's expected digest/revision; request a fresh preview
   or explicit selection before applying changed bytes. Revalidate at Apply
   even when monitors missed an event. Retain unavailable saved IDs visibly.

Discovery changes availability, never the committed appearance, application
provider or installed application output. No network refresh/download or Matugen
generation follows a filesystem event. Retry for a committed application profile
uses its committed bytes; adopting changed templates requires Apply. Opening a
browser may request metadata under its normal cache policy, separately from
filesystem discovery.

Acceptance: external copy, atomic rename, nested image/template edit, invalid
manifest repair, duplicate ID, missing root creation and removal appear without
manual refresh. Cover event storms, scan cancellation, degraded watches, stale
preview rejection, frontend reconnect and watcher teardown. An idle session has
no scan timers or subprocess work, and updates leave committed output unchanged.

## C4 — Application profiles and the real package provider

Implement the [profiles plan's M1–M6](MATUGEN_PROFILES_IMPLEMENTATION_PLAN.md),
including its renderer and adapters (now implemented). Its application
behaviors remain the detailed contract; use the following integration order.

| Step | Implementation | Completion check |
| --- | --- | --- |
| C4a: model and catalog | Add `matugen_profiles.zig`, `theme_provider.zig`, profile manifests and additive preferences with management disabled by default. Merge standalone XDG profiles and profiles from all installed packages with duplicate IDs rejected. | Master Off, per-app Off/manual/theme precedence, unknown/missing IDs, unsupported variants and independent object merges are tested. |
| C4b: full render inputs | Retain complete dynamic Matugen data alongside the shell projection. Validate versioned fixed render data from the effective palette package, including `palette_id` overrides. | Exact supplied values survive; declared shell-role projection matches the package palette; missing roles or incompatible renderer versions produce unsupported status. |
| C4c: worker | Render only selected templates through private Pearl-generated Matugen configuration; add bounded output, cache, deadlines, cancellation and desired/applied revisions. Independent app seed/wallpaper sources work in every shell mode. | No global config/hooks; no generation on browsing, install or preview; obsolete jobs cannot publish; unchanged inputs reuse cache. |
| C4d: adapters and recovery | Implement built-in application adapters, writer lease, per-application preflight/staging, ownership journal, backup/restore and changed-output reload checks. | User edits survive switches, Off and removal; failures/interruption are recoverable; unrelated filesystem destinations are not falsely described as one atomic write. |
| C4e: provider and UI | Supply committed active-package profiles/defaults through the real provider; add Application themes controls, origin/status, install review, retry and restore to the shared editor protocol. | Theme inheritance changes only inherited apps; manual/Off persist; Apply/Discard/merge and activation-required states work across frontends. |

The provider is derived from `package_id`, independently of color/style overrides;
GTK mode has no active package provider. Profiles selected individually remain
available from any installed package. Follow Pearl uses full dynamic render data
or compatible full data from the effective fixed palette. Static/GTK and shell-only
palettes report unavailable full render data; independent application color
sources still work. Never approximate fixed application colors by generating
from a seed.

Capture templates, defaults, adapter contract and full render inputs in immutable
committed provider/profile snapshots. Apply captures new bytes even for a manual
profile whose package is not the active shell theme. Keep application snapshot
references separate from the shell snapshot where necessary, with shared bounded
blob storage and reference accounting. Restart/retry must not read changed mutable
templates. Package removal reports unavailable selection but retains committed
recovery material and last-good outputs; subsequent Apply cannot adopt missing
references. Discovery alone never switches assignments or reconciles new bytes.

Reconcile applications after shell/preferences commit. A failed app does not undo
a valid shell Apply. Missing Matugen, missing profile, unsupported variant and
conflicts get per-app status while preserving last-good output. Off stops new
render/reload work and restores only unchanged Pearl-owned installed files;
standalone generated output may remain. QtEngine/Darkly remains the sole Qt
settings writer; profiles cannot bypass it or run contributed shell hooks.

Initial adapters/templates follow the profiles plan: Zed and Equibop receive
distinct managed theme files with truthful activation guidance; Fluxer and Steam
receive generated CSS and manual setup instructions; Starship installation needs
an explicit review of the concrete configuration diff and a backup. Verify pinned
template licenses before redistribution. The absent Aqueous template is unavailable,
not fabricated. These are initial adapters, not an enumerated list of community
profile IDs; new profiles for supported adapters require no Pearl code change.

Acceptance: install a new package, enable only Zed, keep Steam Off and choose an
independent Equibop profile. Change active package, palette override and style
separately; verify origin, exact colors, manual precedence and no unintended writes.
Cover renderer failure, removed templates, dark-only profiles in light mode,
offline restart, interruption, writer contention and user-edited destinations.

## C5 — Bootstrap the GitHub community repository

The selected project is `Seafoam-Labs/pearl-community-themes`. Proposed endpoint
and layout decisions below are not live URLs or claims that hosting is configured.

| Item | Planned value |
| --- | --- |
| Repository ID | `seafoam-community` |
| Display name | `Pearl community themes` |
| Default index | `https://raw.githubusercontent.com/Seafoam-Labs/pearl-community-themes/main/index.json` |
| Archives | GitHub release assets, one immutable package ID/version identity per archive |
| Sources | `themes/<package-id>/theme.json` and package-relative assets/templates |
| Index history | Generation-specific pages under `indexes/<generation>/`; root `index.json` points into the same generation |

Choose raw GitHub hosting for the index initially so no Pages site is required.
Consumers use ordinary HTTPS and need no GitHub account, API token or Git client.
Other compatible HTTPS repositories remain supported. Verify redirect counts,
TLS, byte limits and cache behavior against actual hosting before enabling it.

1. Prepare a reviewable repository scaffold: README, contribution/author guides,
   ownership/review policy, package attribution/license requirements, an original
   example and CI configuration. Assign actual maintainers before launch; do not
   invent their identities. Create the GitHub repository as a separate publishing
   action after the scaffold and settings are ready for review.
2. Extend native `pearl-themes` tooling to generate deterministic, paginated
   indexes from validated release records and to validate the complete publication.
   Reuse `validate`, `pack` and `validate_index`; share the runtime package validator
   so publishing cannot accept assets/profiles the client rejects. No Python
   release generator. Record the pinned validator/toolchain versions.
3. Run contribution checks on package data with a trusted pinned validator.
   Check schemas, complete assets, licenses/attribution, supported APIs, profile
   descriptors and rendering fixtures. Treat submitted templates as data, with
   bounded rendering in an isolated test environment and no hooks. Pull-request
   checks have no publishing credentials; trusted maintainers review visuals and
   application outputs before merging. Packages never supply CI commands.
4. Publish validated archives first. Generate metadata from the actual published
   bytes, including exact SHA-256, size, version and capabilities. Publish root
   and generation-specific index pages in one repository commit after every
   archive is reachable. Never replace an existing ID/version's bytes; corrections
   get a new version. Retain old pages/assets for cached clients. Index rollback
   may remove an entry, but must not rewrite its immutable release identity.
5. Publish at least one original image/profile package and a second arbitrary ID
   after the first client build. Run the real download/install/preview/Apply and
   offline flow. Only then enable the default in a Pearl release. A nonexistent
   repository must not become a shipped broken default.

### Default-source behavior and migration

Implement the default in `src/theme/repository.zig` and source management UI.
Use the existing source configuration as the authoritative complete list:
absence of the file means the released built-in default; an existing schema-1
file, including an empty list, means exactly that user's choices. Persist the
complete effective list on add/remove. Removing the default therefore writes an
explicit list without it, and restart/upgrades do not resurrect it. This avoids
new suppression fields in the strict source schema.

Preserve all existing custom sources and receipt origins. For users with an
existing explicit list, offer **Add default community repository**; do not
silently insert it, evict another source at the 16-source limit or overwrite an
ID/URL conflict. Removing configuration deliberately resets to release defaults;
document this. Merely configuring the default performs no startup network request.
Offline errors retain cached metadata and installed packages. Keep the root URL
stable after launch because it participates in immutable release provenance;
any future endpoint migration needs an explicit source/receipt migration design.

Acceptance: fresh private XDG roots list the default after launch; existing/empty
source files remain unchanged; removal survives restart and upgrades; explicit
re-add works; offline startup does not block. A new arbitrary community package
becomes downloadable through index publication alone. Rewriting a published
version still fails the client's immutable-version checks.

## Delivery order and release gate

Land C1 first. C2 and C3 can then be developed independently. C4a/C4b build on C1;
C4c/C4d precede C4e, and C4's committed-byte storage must integrate with C2's
snapshot accounting. C5's scaffold/tooling can start earlier; the hosted default
ships only after C2–C4 validation is available for published packages. Each step
must include its fixtures, focused tests and current-contract documentation.

Extend `test-theme-packages`, `test-theme-repository` and `test-custom-themes`.
Add focused `test-theme-assets`, `test-theme-discovery` and `test-matugen` targets;
exercise publishing-tool determinism and multi-page consistency in repository
tests. Production builds must not include fixture trust roots or crash hooks.
Use private XDG roots, a fixture HTTPS server, bus and compositor; never change
the user's live appearance or application configuration for acceptance.

Before declaring completion, run the applicable ReleaseSafe build/unit, preferences,
Settings appearance/boundary, component, presentation, lock, border, Qt and
packaging checks described in [DEVELOPMENT.md](DEVELOPMENT.md). Reproduce the
recorded Aqueous monitor-removal assertion and obtain a passing presentation
result with a supported compositor, or explicitly retain it as an unresolved
release gate. Cover light/dark, compact/normal, large text, reduced motion, focus,
disabled/error states, narrow windows, multiple outputs and output removal.

Store rendered evidence, exact package/archive/renderer identities and test
reports together. Update the current author, repository, preferences, frontend
API, packaging and development docs, including schema migration, manual app
activation, source removal, downgrade and recovery. Mark original T5/T6/T7 and
profiles M1–M6 complete only when their corresponding acceptance checks pass.
