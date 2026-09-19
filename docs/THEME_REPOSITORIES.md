# Publishing community theme repositories · schemas 1 and 2

A community repository is an HTTPS index plus immutable tar.gz releases. A new
package ID needs no Pearl release. Repository operators choose their own hosting
and contribution policies; there is currently no default hosted repository.

The intended default GitHub project is `Seafoam-Labs/pearl-community-themes`,
which does not exist yet. The [completion plan](CUSTOM_THEMES_COMPLETION_PLAN.md)
defines its proposed index endpoint, native Zig publishing tools, contribution
checks and default-source rollout. Both index schemas are supported. Use schema 2 for image/profile requirements.
The [reviewable scaffold](../community-repository/README.md) includes two original
packages, contribution policy and a read-only CI workflow.

Use [the author guide](CUSTOM_THEMES.md) and native `pearl-themes validate` and
`pack` operations. Include source/license attribution and preview evidence for
dark/light, keyboard focus, disabled/error controls, narrow layouts, increased
font size, compact density and reduced motion. Verify ownership of contributed
assets and preserve the author's exact declared color mapping.

Each index page has `schema_version: 1` or `2`, a stable `repository_id`, `releases`
and optional `next` (an absolute HTTPS URL). Example:

```json
{
  "schema_version": 1,
  "repository_id": "my-community",
  "releases": [{
    "id": "org.example.meadow",
    "name": "Meadow example",
    "author": "Pearl contributors",
    "license": "CC0-1.0",
    "source": "https://example.org/pearl-themes/meadow",
    "version": "1.0.0",
    "url": "https://example.org/releases/meadow-1.0.0.tar.gz",
    "sha256": "REPLACE_WITH_64_LOWERCASE_HEX_DIGITS_FROM_PACK",
    "size": 1234,
    "requires": {"palette_api": 1, "style_api": 1},
    "variants": ["dark", "light"],
    "style": true,
    "description": "Original green colors and component styling."
  }]
}
```

Set `size` to the exact archive byte count and `sha256` to its SHA-256 from
`pack`. The remaining metadata/capabilities must match `theme.json` exactly:
the backend checks them again after downloading and unpacking. Unknown and
duplicate fields, duplicate ID/version pairs and unsupported schemas reject
the index. Description is optional, at most 1,024 UTF-8 bytes. API versions
unsupported by the client remain visible as unavailable releases.

Pages contain at most 16 releases and 96,000 bytes of normalized JSON, with
a 1 MiB download limit. Split larger catalogs using `next`; pages are fetched
only on explicit navigation. All index, next-page, release and redirect URLs
must use HTTPS, with no embedded credentials/fragments. System certificate
verification stays enabled. Redirects are limited to four, connection timeout
to ten seconds and total request time to 45 seconds.

Validate a page before publishing:

```sh
pearl-themes '{"action":"validate_index","path":"index.json","id":"my-community"}'
```

Upload the immutable archive first, then publish the index atomically. Never
change bytes for an existing `(repository URL, package ID, version)`; publish a
new version. Pearl remembers release hashes across pages and removal/readdition.
Different repositories claiming an installed ID cause a source conflict; switching
origin requires explicit removal/import, with active snapshots retained.

Source configuration is `$XDG_CONFIG_HOME/pearl/theme-repositories.json`:
`{"schema_version":1,"sources":[{"id":"my-community","name":"My community",
"url":"https://example.org/index.json"}]}`. Configure it through Settings or
`source_add`; at most 16 sources are supported. Network failures may show cached
metadata marked Offline. Invalid downloaded indexes are errors, not silent cache
fallback. An offline listing does not imply the archive is cached.

Metadata lives under `$XDG_CACHE_HOME/pearl/theme-repositories`, capped at 512
pages. Immutable release history under `$XDG_STATE_HOME/pearl/theme-repository-history`
is limited to 64 repository URLs and 4,096 releases per URL. Reaching a quota
reports `ThemeRepositoryStorageLimit`; it does not silently discard pinned
identities. Removing cache pages is safe; removing release history deliberately
forgets prior version identity and should be an administrator's explicit choice.

Run `zig build test-theme-packages test-theme-repository test-custom-themes`
for contract, HTTPS lifecycle and private-desktop acceptance. The repository test
generates a private certificate trusted only by the instrumented test executable.
Production binaries have no test CA or crash-injection overrides. Test archive
and index examples live in `tests/fixtures/community`; their URLs are placeholders.


## Native publication and the default source

`pearl-themes '{"action":"publish_build","path":"publication.json","output":"/absolute/new/output"}'`
validates packages, license/attribution files and complete resources, then builds
deterministic archives and schema-2 indexes. The input has schema_version 1,
repository_id, index_url ending in `/index.json`, and packages containing path,
HTTPS archive url and optional description. See the scaffold’s publication.json.
Output includes archives, generation-specific pages and root index.json. Duplicate
ID/version records fail. The output directory must not already exist. Failed local
builds can leave reviewable partial output; they never publish it automatically.

Upload archives first and verify the actual hosted bytes against generated hashes
before committing index pages together. Keep old immutable archives/pages. The
CI validator binary URL/hash must be pinned by actual maintainers before launch;
contribution workflows receive no publishing credentials. See scaffold PUBLISHING.md.

The built-in source is gated by `-Dcommunity-theme-repository=true` (default false).
Enable only after the GitHub project exists and real download/Apply/offline checks
pass. Its stable URL is
`https://raw.githubusercontent.com/Seafoam-Labs/pearl-community-themes/main/index.json`,
ID `seafoam-community`. Merely configuring it makes no startup network request.

When enabled, an absent source file means the released default. An existing file,
including an empty list, is the complete authoritative user list. Add/remove saves
that complete list; removal persists through restart/upgrades. Deleting the file
explicitly resets release defaults. Settings offers Add default community
repository (`source_default`) only in enabled builds. It never overwrites an
ID/URL conflict or evicts another source at the sixteen-source limit. Existing
custom sources and receipt origins remain unchanged.

`verify_profiles` takes a package path and explicitly renders every declared
profile/variant in private temporary storage. It reports hashes of the outputs,
uses fixed full package data where supplied, otherwise exercises profiles against
seed #6750a4, and never calls installation adapters. CI uses this separate action
with the pinned Matugen executable; ordinary validate/install/browse do not render.

For independent syntax/visual review, `verify_profiles` accepts an optional
absolute `output` directory which must not exist. It saves the bounded generated
files under profile ID/variant there, while keeping all app installation adapters
disabled. Pearl’s development tests parse native Zed output as JSON and Starship
output as TOML using independent standard parsers. No Python validator is deployed.
