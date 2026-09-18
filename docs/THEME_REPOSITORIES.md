# Publishing community theme repositories · schema 1

A community repository is an HTTPS index plus immutable tar.gz releases. A new
package ID needs no Pearl release. Repository operators choose their own hosting
and contribution policies; there is currently no default hosted repository.

Use [the author guide](CUSTOM_THEMES.md) and native `pearl-themes validate` and
`pack` operations. Include source/license attribution and preview evidence for
dark/light, keyboard focus, disabled/error controls, narrow layouts, increased
font size, compact density and reduced motion. Verify ownership of contributed
assets and preserve the author's exact declared color mapping.

Each index page has `schema_version: 1`, a stable `repository_id`, `releases`
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
