# Phyto thumbnails and file previews

Status: initial release implemented (T0–T3); T4 remains a follow-up · September 25, 2026.
See [implementation details and validation](THUMBNAILS_PREVIEWS_IMPLEMENTATION.md).

Add recognizable thumbnails to the file views and useful, read-only previews to
the details sidebar and a dedicated preview window. Build on Phyto's native
Zig/GTK4/GIO implementation. Deliver local raster images and text first, then
optional PDF and video stills. The original proposed defaults below are retained for comparison with the
implementation report, which records final behavior and differences.

## Existing code and integration points

| Current code | Planned change |
| --- | --- |
| `src/tab.zig`: monitored `GtkDirectoryList`, filter/sort models, shared selection | Retain the model pipeline; request thumbnail metadata and track content revisions. |
| `tab.zig`: recycled factories display 48 px grid / 20 px list MIME icons | Add a fixed visual slot with icon fallback and an asynchronously supplied picture. |
| `tab.zig`: `unbind` only clears `phyto-item` | Cancel subscriptions, invalidate binding tokens and release pictures before reuse. |
| `Tab.navigate` increments `generation`; `refresh` does not | Give all preview-invalidating changes a revision, including refresh and monitor changes. |
| `Window.updateDetails` rebuilds the sidebar and displays a 72 px icon | Retain a preview controller across routine updates and change requests only when the selected identity/version changes. |
| `Window.layout` hides details below 1000 px and in split view | Make explicit preview available in a separate transient window at every layout width. |
| `actions.zig`, `context_menu.zig`, `context.zig` | Add one Preview action with captured file and originating-tab identity. |
| `platform/preferences.zig` | Persist thumbnail policy and file-size limit; propagate changes to all windows. |
| `tests/native.py` | Add real image fixtures: existing `.png` and `.pdf` fixtures contain plain text. |

This expands the thumbnail direction in [the main implementation plan](IMPLEMENTATION_PLAN.md)
without requiring its proposed larger source-tree reorganization.

## User-visible behavior

- **Grid:** replace eligible file icons with contained thumbnails in a stable
  80 × 64 logical-pixel area. Keep two-line names, selection and focus visible.
  Fit the whole image; do not crop documents or stretch portrait images.
- **List:** show thumbnails in a 24 px visual slot without increasing row height.
  Directories and unsupported files retain their existing MIME icons.
- **Details:** one selected supported file shows a larger image or bounded text
  excerpt above its metadata. Multiple selection shows a count/summary and does
  not decode an arbitrary first item. Hidden details create no preview demand.
- **Quick preview:** add Preview to the single-file context menu and overflow
  actions. Space opens it only when the file view has focus, exactly one file is
  already selected, and no modifiers are held. Preserve modified Space selection
  behavior and text-entry input. Test GTK event propagation explicitly.
- Use one transient, non-modal preview window per browser window. It captures
  the requested file, shows its name and an Open button, closes with Escape, and
  restores focus to the originating view when still present. A later Preview
  action replaces its target; ordinary selection changes do not retarget it.
  Reuse existing opening restrictions for executables and desktop entries.
- Show MIME icons immediately while work is pending. Background thumbnail errors
  leave the icon in place; explicit preview can explain unsupported, too large,
  unreadable or removed files. Do not open repeated error dialogs.
- Keep image animation and media autoplay disabled. Text is selectable and
  read-only; HTML and Markdown display as source text, without executing content.

| File class | Initial release | Follow-up capability |
| --- | --- | --- |
| JPEG, PNG, supported WebP/GIF | Thumbnail, sidebar image, larger fit-to-window preview; first frame only | Additional verified raster formats |
| UTF-8 plain text, source, Markdown, JSON | MIME icon plus sidebar/quick text preview | Syntax highlighting if justified separately |
| PDF | MIME icon and unsupported-preview state | First-page thumbnail and larger first-page preview through an optional provider |
| Video | MIME icon and unsupported-preview state | Representative still through an optional provider |
| SVG, RAW, office documents, archives, audio | MIME icon and metadata | Separate provider proposals; no implied rendering support |
| Directories, symlinks, special files | Existing icons and metadata | No folder mosaics or automatic symlink traversal in this plan |

Use content type and decoder capability, not the filename extension, to select a
renderer. Initially require a readable regular native file; never open FIFOs or
devices for preview. Network mounts can expose native paths, so consult available
filesystem information and suppress automatic reads for known remote mounts.
Unknown mount locality is a documented limitation, not a claim of offline safety.

## Service, lifecycle and rendering

Add `src/core/preview.zig` for testable eligibility, cache-key and request-state
logic; `src/platform/thumbnails.zig` for the process-shared scheduler/cache;
`src/preview.zig` for sidebar and preview-window controllers. Keep the existing
flat layout for current files.

Requests carry a canonical GFile URI, source version (mtime, size, and finer
timestamp/etag when available), size bucket and renderer version. Consumers also
carry a window/tab identity, navigation revision and binding/selection token.
Deduplicate work by source/version/size; detach consumers independently.

1. Bind a row, reset it to the MIME icon and subscribe using a new binding token.
2. Check memory, then a validated disk thumbnail, then enqueue generation.
3. Prioritize explicit preview, visible details, then rows in the active views.
   Bound the queue; GTK can bind rows outside the visible viewport, so binding
   alone is not permission to generate an entire directory. Suppress inactive
   tabs and the hidden grid/list view; skip prefetch in the first release.
4. Deliver pixels on the main context only after checking source version and
   consumer tokens. Workers own data and file references, never raw GTK pointers.
5. Unbind, navigation, refresh, hidden views and close detach subscriptions.
   Cancel work with no remaining consumers; finish and clean up every callback.
   App/service lifetime must outlast completion cleanup, including last-window close.

Use `GtkPicture` with a supplied paintable and contain fitting inside the fixed
slot. Avoid convenience file-loading calls on the UI path. This widget supports
paintables and explicit fitting; verify APIs against the pinned bindings, since
online GTK documentation may describe newer versions. [GTK Picture documentation](https://docs.gtk.org/gtk4/class.Picture.html).

The proposed decoder is a small Zig helper executable using the generated
GdkPixbuf bindings for scaled raster decoding, orientation and PNG metadata.
Prove binding/API availability before adopting it. Scaled stream decoding exists,
but scaling alone does not establish a bound on a decoder's internal allocations.
[GdkPixbuf scaled stream API](https://docs.gtk.org/gdk-pixbuf/ctor.Pixbuf.new_from_stream_at_scale.html).

Run decoding outside the UI process with bounded input/output, memory and wall
time; terminate and reap a stalled helper. Validate its output dimensions and
byte length before allocating textures. Process isolation alone is not a security
sandbox: the initial allowlist is raster-only and additional complex providers
must have a documented confinement policy. The helper should accept only the
selected input and return bounded pixels/metadata, with no shell interpolation.

Proposed initial limits, to measure and tune in the first implementation milestone:

| Resource | Starting limit |
| --- | --- |
| Concurrent image jobs | 2; hard ceiling 4 across all windows |
| Pending unique jobs | 128; discard low-priority, unneeded requests first |
| Texture memory | 64 MiB including displayed/pinned textures; downscale or defer when full |
| Automatic image source | 50 MiB encoded, 64 megapixels advertised dimensions |
| Helper | 512 MiB memory ceiling, 5-second thumbnail / 10-second explicit-preview timeout |
| Explicit image output | At most 2048 px on the long edge, within the texture budget |
| Text read | 64 KiB and 500 displayed lines; mark truncation and handle partial UTF-8 boundaries |

Treat limits, cancellation and transient read failures separately from permanent
unsupported/invalid content. No automatic retry loop when a decoder fails.

## Cache, invalidation and preferences

Use the freedesktop thumbnail cache so existing desktop thumbnails can be reused:
PNG files beneath `$XDG_CACHE_HOME/thumbnails`, keyed by MD5 of the canonical URI,
with the appropriate 128/256/512/1024 size class for logical size × display scale.
[Cache directories](https://specifications.freedesktop.org/thumbnail/latest/directory.html),
[cache naming and saving](https://specifications.freedesktop.org/thumbnail/latest/thumbsave.html).

- Validate stored `Thumb::URI` and `Thumb::MTime`, plus `Thumb::Size` when present;
  write these fields for generated thumbnails. Use stronger available source
  version information for in-memory invalidation and recheck after decoding.
  Missing/unverifiable metadata is a cache miss. [Modification detection](https://specifications.freedesktop.org/thumbnail/latest/modifications.html).
- Query `thumbnail::path`, `thumbnail::is-valid` and failure metadata lazily for
  demanded items. Treat missing GIO attributes as unknown, not valid. Validate
  cached PNGs and their size just like other image inputs. [GIO validity attribute](https://docs.gtk.org/gio/const.FILE_ATTRIBUTE_THUMBNAIL_IS_VALID.html).
- Create private cache directories/files (0700/0600), write a temporary sibling
  and atomically rename complete PNGs. Cache write failure must not prevent
  displaying a successfully generated image. Do not recursively thumbnail the
  thumbnail cache itself.
- Record deterministic generation failures under a Phyto-specific failure
  namespace keyed to source version; cancellation, missing providers and resource
  limits must remain retryable. [Failure cache convention](https://specifications.freedesktop.org/thumbnail/latest/failures.html).
- Invalidate consumers and textures on monitor changes, rename, replacement,
  delete and refresh. Re-query source metadata before publishing; a rename starts
  a new URI key. Watch an explicitly previewed file even after its tab navigates.
- Bound cache writes with a proposed 256 MiB Phyto generation budget and track
  owned entries for cleanup. Prune only entries whose ownership/version still
  matches; never sweep another application's shared thumbnails. Larger quick
  previews and text excerpts stay in memory.

Persist **Show thumbnails: Local files / Never**, default Local files, plus the
automatic file-size cap and **Preview in details**, default enabled. Turning
thumbnails off cancels automatic thumbnail work and clears displayed thumbnails;
the details toggle separately controls automatic sidebar reads. Explicit Preview
remains available for eligible local files. Remote GIO content previews are
deferred; a future opt-in must define download limits and disk-cache policy.

## Delivery sequence and acceptance gates

| Milestone | Work | Acceptance gate |
| --- | --- | --- |
| T0 — Prove decoder and contracts | Verify Zig 0.16/pinned bindings, helper build/install, JPEG/PNG decode, PNG metadata, orientation, cancellation and enforced limits. Record runtime dependency changes. | A real image round-trips through the helper and standard cache; malformed and stalled inputs terminate cleanly. Resolve backend gaps before UI integration. |
| T1 — Thumbnail service | Implement pure policy/state, scheduler, helper protocol, memory/disk caches and invalidation. | Cache hit/miss/stale cases, queue budgets, deduplication and last-consumer cancellation pass deterministic tests. |
| T2 — Grid/list thumbnails | Connect factories, visibility tracking, preferences and scale changes. | Correct thumbnails survive fast scrolling, sorting/filtering, refresh, edits and tab/split/window changes with no stale row images. |
| T3 — Sidebar and quick preview | Add selection controller, image/text views, Preview action, focus/Escape behavior and file monitoring. | Single/multiple selection, keyboard access, narrow/split layouts and closing during decode pass native tests. T0–T3 form the initial release. |
| T4 — Optional document/media stills | Add explicit provider adapters for PDF first-page and video still generation; capability detection, argv invocation, timeout/output checks and packaging guidance. | Missing/crashing providers retain useful fallback; supported fixtures display accurate stills. No document navigation or media playback is implied. |

For T4, select and document concrete providers after checking installed/runtime
availability. Do not execute arbitrary discovered thumbnailer command strings.
Update `build.zig`, package install rules and `docs/PROVIDERS.md` for the chosen
adapters; PDF/video support must remain optional at runtime.

## Verification and completion

- Add unit tests for source/version keys, policy, queue priority, cancellation,
  memory accounting and late-completion rejection. Test the helper/cache with
  real fixtures, including corrupt/truncated input, misleading extensions,
  enormous dimensions, EXIF rotation, transparency and unusual URI characters.
- Add `tests/previews_native.py` and a `zig build test-previews` target using the
  existing private compositor/D-Bus harness and disposable home/cache directories.
  Exercise recycled rows, selection races, two windows sharing a request, live
  file replacement, permission changes, disk-full cache writes and close-in-flight.
- Verify the initial format matrix using actual image/text content and separate
  intentional invalid fixtures. Test providers both present and absent in T4.
- Capture dark/light/native themes, compact rows, 1×/2× scale, narrow/split views,
  sidebar, quick preview and fallback states. Check accessible names, keyboard
  focus, text selection and Escape behavior.
- Measure cold/warm scrolling through 10,000 mixed files. Record hardware,
  main-loop stalls, peak memory, active/queued jobs and cache hits. Target no
  preview-attributable main-loop stall over 50 ms and enforce configured budgets;
  adjust proposed limits from evidence before declaring performance complete.
- Run `zig build test`, `zig build integration -Doptimize=ReleaseSafe`,
  `zig build test-context-menus -Doptimize=ReleaseSafe`, and the new preview suite.
  Document supported formats, limits, dependencies and results in the README and
  implementation report. Thumbnail/preview failures must not block file actions.

The initial implementation covers T0–T3; its evidence and remaining qualification
limits are recorded in the implementation report. T4 is specified in the
[PDF and video provider implementation plan](PDF_VIDEO_PROVIDERS_PLAN.md).
