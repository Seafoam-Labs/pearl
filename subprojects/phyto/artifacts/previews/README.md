# Native preview verification

Disposable fixtures and private compositor/D-Bus sessions, September 25, 2026.
Screenshots are unaltered native window-region captures. Images use generated
color fixtures so decoded pixels, aspect ratio and alpha can be checked without
external source assets.

- [Preview acceptance report](results.json): helper/cache checks and native UI,
  including an actual rendered-pixel assertion for the quick image preview.
- [Navigation/layout regressions](navigation-results.json): nine passing groups.
- [Context-menu/file-operation regressions](context-menu-results.json): fifteen
  passing groups.
- `session/`: logs from the preview suite, including deliberate corrupt-file,
  cancellation and timeout cases. Decoder-error messages in those cases are
  expected. Each report records the tested binary hash.

Build and pure tests: `zig build -Doptimize=ReleaseSafe` and
`zig build test -Doptimize=ReleaseSafe` passed (11 tests).

Host: Linux 7.2.7-1-cachyos, x86_64, AMD Ryzen 9 9950X3D. Native runs use the
repository's private Aqueous harness with the pixman renderer. The preview report
records elapsed time for navigating and scrolling 10,000 mixed tiny PNG/text
fixtures, tracked texture-pixel bytes and main-loop gaps during active jobs.
Job/cache counters and the maximum gap are cumulative within that application
run through the end of the workload; they include the earlier small-file checks.
Pixel storage excludes process/GPU overhead. This is a functional responsiveness
check, not a photographic-library or system-memory benchmark.

Reproduce from `subprojects/phyto`:

```sh
zig build test-previews -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
```

Pillow is required only to encode/inspect test images. Native tests require local
socket and subprocess access for the compositor, D-Bus and installed image loader.
See [implementation and qualification limits](../../docs/THUMBNAILS_PREVIEWS_IMPLEMENTATION.md).
