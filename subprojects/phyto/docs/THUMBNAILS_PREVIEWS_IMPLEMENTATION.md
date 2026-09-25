# Thumbnails and previews implementation

Implemented September 25, 2026: the initial T0–T3 release from the
[preview plan](THUMBNAILS_PREVIEWS_PLAN.md). Optional PDF/video providers (T4) are now implemented in a
[separate extension report](PDF_VIDEO_PROVIDERS_IMPLEMENTATION.md). This document
retains the original raster/text release evidence.

## Behavior

Grid and list views display local raster thumbnails with stable visual slots,
preserved aspect ratio and MIME-icon fallback. The details sidebar previews one
selected image or UTF-8 text file; multiple selections show a count. Hidden
details and inactive views do not request previews.

Space on a single file, the context-menu Preview action and the overflow Preview
action open a transient window. It captures the requested file, monitors changes
even after the originating tab navigates, provides Open through the existing
launch policy, and closes with Escape. Multiple-selection Space and modified
Space keep GTK selection behavior. Text remains selectable source text, including
HTML and Markdown. Directory, symlink, special-file and remote-URI content is not
decoded. Native mounts reported as remote by GIO are rejected as well.

File view options persists thumbnail/details toggles and a 1–50 MiB image cap;
the background menu exposes the toggles too. Changes reach other windows in the
same application process. Explicit previews remain available when automatic
previews are disabled. Separate application processes read preferences at startup.

## Implementation

| Module | Responsibility |
| --- | --- |
| `src/core/preview.zig` | Format policy, scale buckets, URI hashing and validated result protocol |
| `src/preview_helper.zig` | Display-independent helper mode, source checks, image/text decoding and cache validation |
| `src/platform/thumbnail_cache.zig` | Atomic disk-cache writes, bounded ownership journal and conservative pruning |
| `src/platform/thumbnails.zig` | Process-shared queue, deduplication, priorities, cancellation and texture LRU |
| `src/preview.zig` | Visible-row subscriptions, image/text surfaces and monitored preview windows |

The helper is a mode of the same executable, entered before GTK initialization.
The scheduler launches `/proc/self/exe` with an argv array, so packaging Phyto
under another executable name needs no additional install rule. Generated
GdkPixbuf bindings come from the existing pinned GObject package. Verified local
versions: Zig 0.16.0, GTK 4.22.5, GLib 2.88.3, GdkPixbuf 2.44.7. Pearl's Arch
package variants already declare GdkPixbuf; no new runtime package is added.

Only JPEG, PNG, GIF and WebP signatures select raster decoders. MIME capability
checks happen before scheduling; extension-only impostors fail cleanly. Images
are scaled in the helper, retain alpha and EXIF orientation, and use a still
frame. The parent validates dimensions and byte length before creating a memory
texture. Image decoding and disk access stay outside the GTK UI process.

The helper opens sources with no-follow/nonblocking flags, verifies regular-file
metadata, and compares the opened descriptor and current pathname after reading.
This detects in-place edits and replacement/rename races. It selects GIO's local
VFS to avoid session GVfs activation for native-only work. Resource limits are
512 MiB address space, 64 megapixels, a 50 MiB maximum encoded image and a
5-second automatic / 10-second explicit timeout. Full preview pixels are capped
at a 2048 px long edge. The configured encoded-size cap applies to both automatic
and explicit image previews. Text reads stop at 64 KiB / 500 lines and preserve
UTF-8 boundaries; invalid encodings and binary control bytes get a fallback.

The scheduler admits two running jobs and 128 pending unique requests. Explicit
previews take priority over details and rows. Rows request work only when mapped
and intersecting their scroll viewport. Map/unmap, scroll and layout events
coalesce into a one-shot update; production has no preview polling/animation loop.
GTK's extra bound rows do not trigger whole-directory generation.

Listeners pin entries and detach synchronously on unbind, hidden views, retarget
and teardown. Removing the last listener cancels queued work or kills the helper;
the completion still drains/reaps the subprocess and releases its application
hold. A new binding cannot receive the former binding's result. Source version,
URI, output size, policy and text capability form the cache key. Pinned entries
count toward the 64 MiB texture-pixel budget, and unpinned entries are evicted by
last use. This is a pixel-storage budget, not a claim about total RSS or GPU memory.

## Disk cache and differences from the proposal

The helper directly reads standard freedesktop size-class paths. It validates
PNG `Thumb::URI`, `Thumb::MTime`, optional `Thumb::Size`, and Phyto nanosecond
mtime metadata. It does not rely on GIO `thumbnail::path` hints. This keeps cache
reads and metadata validation off the UI thread and works without a thumbnail
daemon. Standard cache naming and size classes follow the
[thumbnail specification](https://specifications.freedesktop.org/thumbnail/latest/thumbsave.html).

Writes use private directories/files and atomic replacement. Cache failures do
not prevent showing decoded pixels. An ownership journal under
`$XDG_CACHE_HOME/phyto` bounds Phyto's generated entries to 256 MiB and 4096
receipts. Cleanup compares recorded content hashes before deleting entries, so
files replaced by another application survive. The journal is persisted before
the image, preventing untracked writes when the journal cannot be saved. Large
explicit images and all text previews are memory-only.

Only explicit GdkPixbuf corrupt-image errors create versioned failure PNGs in
`thumbnails/fail/phyto-1`. Generic loader failures, missing providers, cancellations
and resource limits stay retryable after a new request. Some installed decoders
report malformed files as generic errors, so those are not persistently cached.

The details surface is retained by selected identity/version rather than rebuilt
on every status update. Slot subscriptions supply the lifetime token instead of
passing raw row pointers to worker callbacks. The image surface uses an unmeasured
picture overlay, keeping image dimensions from changing row geometry.

The regression suite also exposed a navigation focus race: entering location or
search editing now clears deferred directory-focus requests. Late enumeration
cannot steal focus while a new location is being typed.

## Validation

Commands run from `subprojects/phyto` with the repository Zig cache:

```sh
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
zig build test-previews -Doptimize=ReleaseSafe
```

The preview suite creates actual PNG/JPEG/WebP/GIF and text fixtures, independently
checks helper output, and uses the existing private compositor/D-Bus harness for
native interactions. Pillow encodes test fixtures only. It verifies scaling,
transparency, EXIF orientation, Unicode URI keys, warm cache reuse, sub-second
invalidation, corrupt caches, file-size limits, bounded text, binary/symlink/FIFO
rejection, failed cache writes and ownership-safe pruning.

Native checks cover grid/list/sidebar/quick preview, multi-selection, context
targets, monitored replacement/removal, preference changes, 10,000 mixed files,
recycled row identities, tabs/windows, dark/light/native themes, compact/narrow
layouts and 2× display scale. Test-only helper delays make cancellation and
timeouts deterministic. GTK warnings are fatal in these runs. These delay hooks,
F12 probes and responsiveness sampling are absent from normal builds.

Results and measurements: [preview report](../artifacts/previews/results.json),
[navigation regressions](../artifacts/previews/navigation-results.json), and
[context-menu regressions](../artifacts/previews/context-menu-results.json).
The build and all 11 pure/operation unit tests pass.
Captures: [grid/details](../artifacts/previews/grid-details-dark.png),
[list](../artifacts/previews/list.png), [image preview](../artifacts/previews/quick-image.png),
[text preview](../artifacts/previews/quick-text.png),
[narrow](../artifacts/previews/narrow.png), [2×](../artifacts/previews/scale-2.png).
The mixed-file benchmark uses small synthetic images; its timing and pixel
storage measurements are not an RSS benchmark for a large photographic library.

Remaining manual qualification: Orca/high-contrast checks, live network-mounted
filesystems, cache exhaustion on a genuinely full filesystem, and broader memory
pressure with large photographs. Cache write failure is automated using an
unusable cache path. The installed decoder's own isolation remains active; the
helper's process/resource limits alone are not a general security sandbox.

PDF/video stills are delivered by the [T4 extension](PDF_VIDEO_PROVIDERS_IMPLEMENTATION.md).
SVG/RAW/office providers, media playback, remote downloads, syntax highlighting
and document page navigation remain outside this release.
