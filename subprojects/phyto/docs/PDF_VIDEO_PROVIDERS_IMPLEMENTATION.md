# PDF and video preview providers

Implemented September 25, 2026 from the [T4 plan](PDF_VIDEO_PROVIDERS_PLAN.md).
PDF first pages and video stills use the existing grid/list thumbnails, details
sidebar and Space preview window. Details and Space identify the image as
“First page” or “Video still”. Automatic-preview preferences and the existing
Open/Escape behavior also apply to these formats.

## Providers and dependencies

- PDF: `/usr/bin/pdftoppm` (Poppler), first page, crop box, document rotation,
  annotations and a white page background. Password-protected documents fall back
  without requesting or storing passwords.
- Video: `/usr/bin/ffprobe` and `/usr/bin/ffmpeg`. MP4/MOV, Matroska/WebM and AVI
  containers; software decoding, first actual video stream, excluding attached
  cover art. Seek to 10% of duration, capped at 30 seconds; unknown duration uses
  zero. An empty successful seek gets one retry at zero within the original deadline.
- Both require `/usr/bin/bwrap` and working unprivileged namespaces. Discovery
  launches a real sandbox and probes the tools outside the GTK thread. Failure
  leaves icons and explanatory details/Space text; converters never run unsandboxed.

The Arch release, Git and Intel Git packages list `poppler`, `ffmpeg` and
`bubblewrap` as optional dependencies. No converter libraries are linked into
Phyto, and the app still builds and runs without these packages. Fixed system
executable paths are used; PATH, arbitrary thumbnailer descriptors and context-menu
scripts cannot select a renderer. Qualified development tools: Poppler 26.08.0,
FFmpeg n9.0.2 and bubblewrap 0.13.0. Other builds must support the invoked options;
codec support follows the installed FFmpeg build.

## Execution and resource limits

The helper verifies the native regular source and its expected size/mtime, rejects
symlinks and known remote filesystems, then supplies its open descriptor as a
read-only seekable `/input/source`. It rechecks descriptor and pathname identity
before displaying or caching successful output. Converters do not reopen a user
pathname or see adjacent files.

The Linux runner uses private mount/PID/IPC/network namespaces, dropped
capabilities, a new session and parent-death handling. Only system runtime/font
paths, a minimal private `/dev`/`/proc`, an empty home and the one input file are
exposed. A 1 MiB temporary filesystem is available; the host home, session sockets,
network and cache are absent. FFmpeg additionally restricts input protocols to
`file` and demuxers to `mov,matroska,avi`; its output permits only `pipe`.

The Zig runner owns fork, descriptor setup, poll and reaping through libc and
Linux interfaces. Provider selection, metadata parsing, image validation and UI
scheduling are also implemented in Zig. Cancellation or helper death tears down
the sandbox's PID namespace, including converter children.
The supervisor drains stdout and stderr concurrently. Production discards stderr;
instrumented tests retain at most 16 KiB for diagnosing failures.

| Limit | Behavior |
| --- | --- |
| Source | PDF 50 MiB; video 2 GiB; existing configurable image cap remains image-only |
| Work | Two total decode jobs across windows, at most one PDF/video job |
| Time | 5 seconds automatic, 10 seconds explicit, including probe/render/retry; probe subdeadline 2 seconds |
| Address space | 512 MiB per helper/converter process; converters use an explicit 8 MiB stack ceiling and two allocator arenas |
| Threads | FFmpeg decode at most two; filter and PNG encoder one |
| Probe | 64 KiB JSON, at most 32 stream records, 5 MiB probe-size setting and 2-second analysis setting |
| Pixels | Maximum 2048 px edge and 16 MiB RGBA; generated PNG maximum 20 MiB |
| Cache | Existing 64 MiB texture-pixel and 256 MiB owned-disk budgets; individual disk PNGs at most 8 MiB |

The parent also reads helper output asynchronously with an explicit byte ceiling,
then validates the private `PHT2` header, status, dimensions and exact RGBA length.
Generated PNG framing/dimensions are checked before helper decoding; concatenated
or trailing output is rejected. The GTK process never parses a PDF/video or PNG.
Rotation and sample aspect ratio are normalized for video. Small video frames are
not upscaled during generation. Recognized PQ/HLG HDR material falls back until a
separate tone-mapping policy is implemented. No playback or PDF page navigation is
provided.

## Cache and capability changes

Provider discovery is shared per process. Explicit Preview retries missing-provider
capabilities after a five-second throttle; restarting also rediscovers tools.
Request identities include provider ID and capability generation. Disk PNGs retain
freedesktop URI-hash names and source metadata, adding `Phyto::Provider` and
`Phyto::ProviderVersion`. The latter fingerprints adapter policy plus executable
path, device/inode, size and nanosecond timestamps. Upgraded executables invalidate
disk entries; restart Phyto to refresh already-resident successful textures.

PDF/video cache hits require matching Phyto provider metadata; foreign thumbnails
are not used because their page/frame selection is unknown. Existing raster cache
interoperability and ownership-based pruning are preserved. Cache-write failure
still permits a generated preview.

Two conservative adjustments from the proposed plan avoid misleading classification:
provider failures use a short in-memory retry cooldown, with no new persistent
failure namespace, because converter exit codes do not reliably separate corrupt
content from unavailable codecs or resource failures. Protected PDFs receive the
same generic fallback as other rendering failures; stderr is not used as a
locale-dependent password detector. These cases can be retried without cache removal.

## Verification

`tests/providers_helper.py` generates its own two-page, rotated and password-protected
PDFs and short video fixtures. It checks page identity, real encrypted-PDF validity,
container/codec stills, rotation, anamorphic geometry, no upscaling, audio-only and
cover-art rejection, playlist rejection, source limits, warm cache behavior and
provider metadata and source changes during conversion. The native allowlist also
accepts current GIO `video/matroska` and `video/vnd.avi` names. Test-only executable overrides exercise missing tools, disabled
sandboxing, crashes, output/stderr floods, deadlines and descendant cancellation.
Canary checks return a valid image only after verifying source-sibling/home/session
isolation and inability to connect to a listening host loopback socket. Overrides
are compiled out of normal builds.

The release build and all 15 unit tests pass. The navigation suite passes nine
groups and the context-menu suite passes fifteen. Pure tests cover metadata selection, unknown duration, HDR/dimension rejection,
malformed results and generated PNG framing. The native suite asserts actual PDF
and video pixels reached the compositor, exercises grid/list/details/Space, theme
and scale variants, keyboard closure and missing-provider states. It also retains
all original raster/text, cancellation and 10,000-entry viewport checks. Window
closure explicitly clears details previews before detaching the window content,
so GTK retention of the details container cannot retain a preview subscription.

See [preview results](../artifacts/previews/results.json),
[PDF capture](../artifacts/previews/quick-pdf.png) and
[video capture](../artifacts/previews/quick-video.png). Provider results include a
5 ms sampled sum of process-tree RSS; shared pages may be counted more than once.
This is a fixture workload measurement, not an exhaustive codec or large-library
benchmark. Existing manual qualification gaps (screen readers/high contrast,
live network mounts and real disk exhaustion) remain documented in the
[initial implementation report](THUMBNAILS_PREVIEWS_IMPLEMENTATION.md).

Reproduce from `subprojects/phyto`:

```sh
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
zig build test-preview-providers -Doptimize=ReleaseSafe
zig build test-previews -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
```

Provider tests require the real tools and working sandbox; missing dependencies
fail visibly rather than silently skipping coverage. Native tests additionally use
the existing disposable compositor/D-Bus harness and Pillow fixture tooling.
