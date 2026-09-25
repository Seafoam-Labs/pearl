# PDF and video preview providers

Status: proposed T4 implementation plan · September 25, 2026.

Extends the implemented [thumbnail and preview pipeline](THUMBNAILS_PREVIEWS_IMPLEMENTATION.md)
and completes T4 of the [original plan](THUMBNAILS_PREVIEWS_PLAN.md).
This document specifies future work; PDF/video rendering is not implemented yet.

## Outcome and scope

Local PDF files show their first page, and local videos show one representative
frame, in grid/list thumbnails, the details sidebar and the Space preview window.
Use the existing picture surfaces, aspect-ratio handling, visibility scheduling,
selection tracking and Open action. Existing automatic-preview toggles apply;
Space remains available when automatic previews are disabled.

PDF navigation, password entry, document text selection, playback, audio previews,
remote content, playlists, SVG/RAW/office formats and arbitrary `.thumbnailer`
execution are outside T4. Context-menu `.action` scripts are not preview providers.

| Provider | Runtime tools | Initial supported content |
| --- | --- | --- |
| `poppler-pdf-v1` | `pdftoppm` and `bwrap` | First PDF page, including scanned pages; white page background, crop box and document rotation |
| `ffmpeg-video-v1` | `ffprobe`, `ffmpeg` and `bwrap` | Local MP4/MOV, Matroska/WebM and AVI containers, subject to installed codecs; one SDR still |

Use fixed built-in adapters and executable argument arrays. No shell commands,
plugin discovery from browsed folders, direct Poppler/libav linkage or automatic
package installation. Missing dependencies leave ordinary file operations usable.

## Existing integration points

The service currently admits only raster/text MIME types. Its request key has no
provider version, its helper only recognizes raster signatures, and cancellation
terminates a single helper process. `communicateAsync` buffers helper stdout before
validating it. These assumptions must change before adding external converters.

| File | Planned change |
| --- | --- |
| `src/core/preview.zig` | Provider IDs, MIME routing, provider-specific limits, versioned result/status validation and request policy tests |
| New `src/platform/preview_providers.zig` | Asynchronous capability snapshot, fixed executable resolution and provider fingerprints |
| New `src/platform/preview_runner.zig` | Helper-side sandbox construction, bounded pipes, converter lifecycle and cancellation |
| New `src/platform/preview_pdf.zig` | Poppler argv and first-page output validation |
| New `src/platform/preview_video.zig` | Bounded probe parsing, stream/frame selection and FFmpeg argv |
| `src/preview_helper.zig` | Retain source ownership/checks; dispatch adapters; validate generated PNG; publish RGBA and cache entries |
| `src/platform/thumbnails.zig` | Provider-aware admission/key, one heavy job, bounded asynchronous result reading, capability invalidation and process-tree teardown |
| `src/platform/thumbnail_cache.zig` | Preserve ownership/pruning rules; support the new provider failure namespace |
| `src/preview.zig` | Recognized-but-unavailable states, first-page/video-still caption and existing preference behavior |
| `build.zig`, `tests/previews_helper.py`, `tests/previews_native.py` | Provider fixtures, deterministic fault tests and native visual checks |

## Capability detection and user feedback

Resolve tools only from fixed system executable directories (`/usr/bin`, `/bin`,
with canonical-path deduplication). Ignore the current directory and user-controlled
PATH additions. Packaging can supply another fixed directory at build time.
Cache discovery once per application session; perform bounded version/feature and
sandbox probes asynchronously, never once per visible row or on the GTK thread.

The capability record contains provider ID, adapter revision, canonical executable
identity/version, required option support and sandbox availability. Detection is
independent for PDF and video; video requires both FFmpeg tools. A sandbox probe
must actually launch successfully, rather than merely find `bwrap` on disk.
Recheck on explicit Preview after a previous missing-provider result, with a
short retry throttle; reopening Phyto also refreshes capabilities. Installing a
provider must not require deleting cached failure thumbnails.

Keep icons quiet for automatic thumbnail failures. Details/Space show short states:
“PDF preview requires Poppler”, “Video preview requires FFmpeg”, “Preview sandbox
unavailable”, “File is too large to preview”, “Preview timed out”, or “Cannot preview
this file”. Identify protected PDFs only when the adapter can establish that
condition reliably; do not classify every Poppler permission error as encryption.
Do not display raw converter stderr or launch package installers.

Version the private helper protocol as `PHT2`, with a bounded status code alongside
image/text/unavailable results. Reject unknown codes, malformed headers and excess
bytes. Map statuses to UI text in the parent; successful images remain tightly
packed RGBA. Parent and helper are the same executable, so no cross-version
protocol compatibility is required.

## Shared runner and confinement

Keep the helper's native/local, regular-file, no-follow, size and metadata checks.
Open the source once and give the sandbox that descriptor read-only at a fixed
seekable path (`/input/source`) using a verified descriptor-based bind. Do not
reopen the original pathname in converters. Recheck descriptor and pathname
identity before publishing or caching; discard results after replacement or edits.

Use bubblewrap with private mount, PID, IPC and network namespaces, dropped
capabilities, a new session and parent-death handling. Provide read-only system
runtime libraries/tools and required system fonts/fontconfig data, a private
minimal `/dev` and `/proc`, and an empty home. Do not expose user home, source
siblings, host `/run`, session D-Bus, display sockets, devices or the thumbnail
cache. Clear the environment and explicitly set locale, font paths and local GIO
behavior. Any temporary filesystem must have a small explicit size limit.
Audit inherited descriptors; only intended input/output/control descriptors survive.

The supervisor owns the sandbox lifecycle. Combine a PID-namespace reaper with
parent-death/control-pipe handling, and verify all descendants exit when the last
listener detaches, the deadline expires or Phyto exits. Killing only the existing
`gio.Subprocess` helper is insufficient. Drain/reap completion exactly once before
releasing the scheduler slot. Failure to establish confinement disables that
provider; do not silently run converters without it.

Read converter stdout and stderr concurrently with explicit byte ceilings. Abort
on stdout overflow; retain at most 16 KiB of diagnostic stderr while draining or
discarding further diagnostics. Replace the parent's unbounded `communicateAsync`
read with bounded asynchronous header/payload reads as well. No converter output
is trusted merely because it exited successfully. Decode its PNG only in the
helper, validate dimensions before allocation, then send the existing RGBA form.

Initial policy values below are implementation defaults to qualify with fixtures,
not measured guarantees. Change them only with recorded performance evidence.

| Resource | Proposed limit |
| --- | --- |
| PDF source | 50 MiB; independent of the existing image preference |
| Video source | 2 GiB for automatic and explicit requests; seek the file, never load it whole |
| Active work | Existing two jobs overall; at most one PDF/video job, leaving capacity for image/text work |
| Request deadline | Existing 5 seconds automatic / 10 seconds explicit, including probe, rendering and any retry |
| Converter memory | Start with existing 512 MiB address-space limit per process; probe and renderer run sequentially; measure aggregate RSS |
| Converter CPU | At most two decode threads and one filter thread for FFmpeg; wall deadline remains authoritative |
| Probe output | 64 KiB JSON, at most 32 stream records; reject nonfinite numbers, overflow and malformed data |
| Probe work | 5 MiB format probe, 2 seconds analysis setting, 2 seconds wall-clock subdeadline |
| Generated image | Long edge at most 2048 px, PNG stdout at most 20 MiB, decoded RGBA at most 16 MiB |
| Cache | Existing 64 MiB texture budget, 256 MiB owned disk budget, 8 MiB per disk PNG; 2048 px results stay memory-only |

The configured 1–50 MiB image cap continues to govern raster images only. Explain
PDF/video fixed limits in the file-view options help and README. Explicit Preview
does not bypass resource limits. Resource exhaustion is retryable and never a
persistent “bad file” classification.

## PDF adapter

1. Route `application/pdf`; verify a PDF header within a bounded initial prefix
   in the helper. Extensions alone do not authorize rendering.
2. Invoke the resolved `pdftoppm` with `-f 1 -l 1 -singlefile -cropbox -scale-to
   EDGE -png /input/source`, omitting the output prefix for stdout. `EDGE` is a
   validated numeric bucket. Confirm stdout behavior against the qualified build.
3. Render only page one, with its normal rotation and annotations. Preserve the
   page aspect ratio and a white background. Avoid a separate `pdfinfo` process
   because page counting and navigation are outside this release.
4. Require a successful exit and exactly one bounded valid PNG. Password-protected,
   malformed and over-budget files get a useful fallback; do not prompt or pass
   password arguments. Details/Space label the successful surface “First page”.

## Video adapter

1. Route a fixed MIME allowlist for the containers above, including normal GIO
   aliases. Constrain FFmpeg demuxers to `mov`, `matroska` and `avi`, and input
   protocols to `file`; reject playlists, concat inputs, image sequences and
   devices. MIME routing is only a hint: the probe must confirm supported content.
2. Run `ffprobe` inside the same confinement policy with `-show_entries` restricted
   to format duration and video stream index/type, dimensions, duration, sample
   aspect ratio, disposition, rotation and color metadata. Use JSON output and
   `V` stream selection to exclude attached pictures. Select the first actual video
   stream by index; reject audio-only files and invalid/excessive dimensions
   (initial ceiling: 64 megapixels). Do not inspect packets or enumerate frames.
3. Use stream duration, then container duration, when finite and positive. Seek
   to 10% of duration capped at 30 seconds; for unknown duration use zero. If the
   selected position yields no frame, retry once at zero within the same deadline.
   Do not retry decoder crashes or resource failures. This deterministic rule is
   the initial representative-frame policy; black-frame scanning is deferred.
4. Run `ffmpeg -nostdin` with explicit input seek, stream mapping, software decoding,
   one output frame, no audio/subtitle/data output, bounded threads and a fixed
   scale filter. Normalize display rotation and sample aspect ratio before fitting
   the requested bounding box; do not stretch anamorphic material or upscale small
   video. Output a single PNG through `image2pipe`/`pipe:1`; allow `pipe` only on
   output. Keep protocol/demuxer restrictions on both probe and render input.
5. Validate the still in the helper. Details/Space label it “Video still”. Qualify
   SDR color handling first; recognized HDR transfers get unsupported fallback
   until tone mapping has its own verified policy. Codec availability varies with
   the installed FFmpeg build and must be reflected in the tested format matrix.

FFmpeg option ordering and filter expressions must be covered by real fixtures,
including nonzero timestamps, portrait rotation and non-square pixels. Do not
assume the proposed command shape establishes those behaviors by itself.

## Cache identity and retries

Add provider ID, adapter/frame-policy revision and capability generation to the
in-memory request identity. Continue using canonical URI plus source version,
output bucket and limits; listeners from superseded requests cannot receive results.

Keep freedesktop URI-hash filenames and standard `Thumb::URI`, `Thumb::MTime` and
`Thumb::Size` fields. Generated PDF/video PNGs also record `Phyto::Provider` and
`Phyto::ProviderVersion` (adapter policy plus tool fingerprint), alongside existing
subsecond metadata. Reject stale Phyto provider versions. For this first release,
PDF/video requests require matching provider metadata; do not import foreign
thumbnails with unknown page/frame policy. Preserve existing raster interoperability.
Capability/source eligibility is checked before using a provider cache entry.

Keep deterministic provider failures in a separate `fail/phyto-providers-1`
namespace with source and provider versions. Extend the ownership-journal path
allowlist accordingly; preserve existing `fail/phyto-1` handling. Persist a failure
only if the adapter can reliably classify corrupt/unsupported content. Missing
tools/codecs, protected files, sandbox failure, cancellation, timeout, changed
sources and resource/cache errors remain transient. Avoid immediate automatic
retry loops with a short in-memory cooldown; an explicit retry can refresh state.

## Delivery order and acceptance gates

| Milestone | Deliverable | Required evidence before proceeding |
| --- | --- | --- |
| T4.0 — Runner and capabilities | Fixed discovery, sandbox, bounded reads, typed results and full descendant teardown | Fake converters that hang, flood both pipes, fork and crash cannot block GTK, leak children or exceed output bounds; unavailable/disabled sandbox falls back |
| T4.1 — PDF | First-page adapter, metadata/cache revision, all three view surfaces | Real one/multi-page, scanned, rotated/cropped, Unicode-path and protected/corrupt PDF fixtures; correct first page and scale; missing Poppler behavior |
| T4.2 — Video | Probe parser, fixed stream/seek policy, format restrictions and still adapter | Real MP4/MOV, MKV/WebM and AVI fixtures using available codecs; first video stream, attached art exclusion, short/unknown-duration fallback, rotation and pixel aspect ratio |
| T4.3 — Release qualification | UI messages, optional packaging, docs and full regression run | Native rendered-pixel evidence, cancellation/cache/performance measurements and all existing suites passing |

Run PDF/video-specific tests in an isolated home/cache with deterministic generated
fixtures and test-only executable injection. Production must not honor the injection
hook. Cover missing tools individually, incompatible options, invalid JSON/PNG,
huge dimensions, source replacement during probe/render, symlinks/FIFOs, remote
mount rejection, misleading extensions, unreadable inputs, unwritable/full cache,
provider upgrades, warm caches, and owned-cache pruning that preserves foreign files.
Use harmless canary files/listeners to establish that converters cannot read source
siblings or home, connect to host network/session sockets, or leave descendants.

Extend the existing native suite for recycled rows, fast selection changes, two
windows sharing a job, automatic toggles, explicit Preview, close-in-flight and
Escape/focus restoration. Capture dark/light/native themes, 1×/2× scale, compact,
narrow and split views. Wait for actual rendered PDF/video pixels before capture;
a ready slot or visible widget alone does not prove the compositor drew the still.

Measure cold/warm browsing of 10,000 mixed entries, job/queue counts, cache hits,
peak process-tree RSS and GTK main-loop gaps on recorded hardware. Maintain the
existing 50 ms main-loop-stall target; verify heavy jobs stay at one and total jobs
at two. Record unsupported codecs and manual qualification gaps explicitly.

Add `poppler`, `ffmpeg` and `bubblewrap` to optional dependency descriptions in
`packaging/arch/PKGBUILD`, `packaging/arch-git/PKGBUILD` and
`packaging/arch-intel-git/PKGBUILD`; describe bubblewrap as required for either
optional provider. The application must still build and run without these tools.
Provider-enabled CI must require the real dependencies; missing providers may
skip only explicitly optional local fixture groups, with visible skip reasons.

Run `zig build -Doptimize=ReleaseSafe`, `zig build test -Doptimize=ReleaseSafe`,
`zig build integration -Doptimize=ReleaseSafe`,
`zig build test-context-menus -Doptimize=ReleaseSafe` and
`zig build test-previews -Doptimize=ReleaseSafe`. Publish the tested format/tool
matrix, limits, screenshots and results in a provider implementation report, and
update the README only after the corresponding behavior passes.

## Reference checks

Local inspection found Poppler `pdftoppm` 26.08.0, FFmpeg n9.0.2 and bubblewrap
0.13.0. Installed help confirms the proposed Poppler page/scale options and
bubblewrap descriptor binding. These are development observations, not minimum
supported versions or proof that the proposed sandbox works on other systems.
T4.0 establishes required features and packaging compatibility.

- [Poppler upstream](https://poppler.freedesktop.org/), plus installed `pdftoppm -h`
  and `pdftoppm(1)`: PDF converter and page/scale options.
- [FFmpeg CLI documentation](https://ffmpeg.org/ffmpeg.html): seek, stream selection,
  frame limits and option ordering.
- [FFprobe documentation](https://ffmpeg.org/ffprobe.html): selected fields and JSON output.
- [FFmpeg protocols](https://ffmpeg.org/ffmpeg-protocols.html): input protocol allowlists.
- [Bubblewrap upstream](https://github.com/containers/bubblewrap): namespace-based
  confinement; Phyto remains responsible for the actual sandbox policy.
