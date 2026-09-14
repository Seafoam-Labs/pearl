# Clipboard and screenshots

T14 adds a **Clipboard & capture** panel to Pearl's Material and native GTK
appearance paths. Open it from the `clipboard` bar item or with
`pearlctl clipboard show` / `pearlctl capture show`. New default bar groups
include the item; existing explicitly configured groups remain authoritative.
Use the Settings bar-group fields to add `clipboard` to an existing setup.
Clipboard opens the history tab with bounded text previews and image thumbnails;
Capture opens the screenshot tab. The tabs are also reachable by keyboard.

## Clipboard contract

Pearl uses generated **ext-data-control-v1** bindings on GTK's Wayland connection.
GTK remains the only reader of that connection. There is no wl-copy/wl-paste
production dependency, synthetic typing, primary-selection history, persistent
history file, D-Bus clipboard service, or portal ownership change.

The regular selection accepts UTF-8 `text/plain;charset=utf-8` (or `text/plain`)
and `image/png`. PNG takes precedence when both image and text are offered.
Other formats, NUL-containing or invalid UTF-8 text, empty/truncated payloads,
and oversized payloads are rejected. A disappeared owner can leave already
received history intact; selecting an entry creates a fresh data-control source
with its own retained payload. Paste remains an action in the destination app.
Deleting a history entry does not interrupt an already selected payload or an
in-progress paste. Clear releases Pearl's current selection as well as history;
it does not erase a selection owned by another application.

| Resource | Bound |
| --- | --- |
| Retained entries | 20, oldest evicted first; duplicates retained once |
| Retained payload total | 16 MiB |
| Text per entry | 256 KiB |
| PNG input and sanitized clipboard PNG | 8 MiB each |
| PNG dimensions | Each axis ≤ 8192; product ≤ 8,388,608 pixels |
| Incoming pipe transfers | One, cancelled when the selection changes |
| Outgoing pipe transfers | Four, each owns an immutable copy |
| Transfer timeout | Five seconds |
| Per-dispatch pipe read/write | At most 64 KiB, nonblocking |
| Preview | 120 UTF-8 bytes, plain text, control characters replaced |

PNG headers and chunk lengths are checked before decoding. Unknown critical
chunks, duplicate headers, missing/trailing end data and excessive dimensions
are rejected. Only IHDR/PLTE/tRNS/IDAT/IEND reach the explicitly selected PNG
decoder; text, compressed profiles and animation metadata are discarded. Pixel
data is re-encoded through a fresh pixbuf, so input metadata is not re-exported.
This yields a static image; it does not preserve embedded color profiles or PNG
animation. Payload caps also apply to screenshot copies. A larger PNG screenshot
can still be saved even if it cannot enter clipboard history.

Clipboard tracking requires one unambiguous seat. A second seat disables it
conservatively for that Pearl process. Protocol/seat loss closes transfers and
releases objects; an unavailable device is reported instead of pretending to
own the selection.

## Privacy and lock integration

History is memory-only. Selections advertising `x-kde-passwordManagerHint`,
`application/x-keepassxc`, or `application/x-pearl-private` are excluded regardless
of the hint's contents. Hints are advisory: an application that copies an
unmarked secret cannot be distinguished from ordinary text.

Lock requests, authoritative Aqueous lock state, sleep preparation, inactive or
unavailable session state, mismatched native/IPC session identities, and Pearl
polkit prompts suspend these services.
Pearl cancels transfers/capture work, clears history and screenshot previews,
releases its selection, and disconnects data-control collection. Status replies
contain no retained clipboard content while suspended. Changes are applied when
Aqueous state arrives and when lifecycle/authentication state changes, before
waiting for surface reconciliation. Reconnecting skips the initial selection,
so text copied while locked is not imported on unlock. Startup also skips the
pre-existing selection.

Buffers explicitly owned by these services are zeroed before release. This is
not a promise to erase copies held by other applications, GTK, the compositor,
the allocator's prior reallocations, or the operating system. PNG decode and
clipboard re-encode have bounded input/output dimensions and run in the main
context; unusually expensive valid PNGs can delay a dispatch. Screenshot pixel
conversion and encoding use one cancellable worker with an application hold.

## Screenshot contract

The validated path is **zwlr-screencopy-v1 v3**, `wl_shm` v1 and `wl_output` v4,
using pinned XML and generated Zig bindings. Pearl accepts the advertised
8-bit XRGB/ARGB/XBGR/ABGR shared-memory formats. It validates dimensions, stride,
format and allocation size before creating a memfd-backed buffer. Captures are
bounded to 8192 per axis, 8,388,608 pixels and 40 MiB shared memory. Unsupported
formats fail visibly. This is an SDR PNG path; HDR/wide-gamut capture is not
claimed by the private tests.

There is one capture in flight, a 200 ms preparation delay, and a five-second
frame deadline. The panel's capture action hides the panel before requesting a
frame and reports completion through the OSD; reopen the panel to preview, save
or copy. A worker normalizes output rotation/reflection and the protocol's
Y-invert flag. Output removal or geometry/mode/scale change cancels the target.
A cancelled worker cannot publish its result after a lock or target change.
Failure leaves the previous successful screenshot available, except when privacy
suspension clears it. A returned output is resolved again through its current
Aqueous ID and connector.

**Region capture is an output crop, including overlapping visible windows.**
Enter `x,y,width,height` in output-local logical pixels. Negative coordinates,
empty rectangles and regions outside the selected output are rejected. Pixel
bounds use the actual transformed capture buffer, rather than an assumed integer
scale:

```
left   = floor(x * pixel_width / logical_width)
right  = ceil((x + width) * pixel_width / logical_width)
top    = floor(y * pixel_height / logical_height)
bottom = ceil((y + height) * pixel_height / logical_height)
```

Whole-output screenshots retain the native transformed buffer dimensions and
exclude the pointer cursor. Status associates the retained result with its
connector and crop rectangle, including after a later capture fails. The
outward crop includes partially covered edge pixels. It is confined to one
output, independent of that output's desktop origin. The current UI accepts an
explicit rectangle; a pointer-drag region selector is not included.

Aqueous also advertises ext-image capture-source protocols and has a toplevel
capture implementation. Pearl does not expose isolated-window capture until
that separate source/format/occlusion path has its own verified client and tests.
`capture status` therefore reports `isolated_window: false`. Output crops are
never presented as isolated-window images. Existing portal screenshots and
screensharing continue to use the installed portal backend.

Save defaults to `$XDG_PICTURES_DIR/Pearl Screenshots/` (home fallback), with a
unique timestamped PNG name. Files are created privately with atomic,
no-overwrite publication. An explicit absolute path is available through the
CLI. Existing files and symlinks are not overwritten. Save errors preserve the
preview for retry; filesystem writes/fsync use the existing local atomic-file
helper. Saving to slow/network storage can therefore block the request.

## CLI

All commands use Pearl's existing session/display-checked control socket.
Entry IDs and screenshot generations are returned by their respective status
commands; the reused `--generation` flag carries either identity.

```sh
pearlctl clipboard status
pearlctl clipboard show --output OUTPUT_ID
pearlctl clipboard select --generation ENTRY_ID
pearlctl clipboard delete --generation ENTRY_ID
pearlctl clipboard clear

pearlctl capture output --output OUTPUT_ID
pearlctl capture region --output OUTPUT_ID --text 31,41,203,117
pearlctl capture status
pearlctl capture show
pearlctl capture copy --generation SCREENSHOT_GENERATION
pearlctl capture save --generation SCREENSHOT_GENERATION
pearlctl capture save --generation SCREENSHOT_GENERATION --path /absolute/new.png
pearlctl capture cancel
```

Capture requests acknowledge queueing, not completion. Wait for `pending: false`
and an increased `generation`; inspect the message if it did not increase.
Copy/save reject stale generations. There is no clipboard payload argument in
control requests and no bulk payload in status responses.

## Validation and boundaries

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-clipboard-capture -Doptimize=ReleaseSafe
python3 scripts/check-wayland-bindings.py
```

The suite uses private Aqueous outputs, D-Bus services, generated-Zig clipboard
producers and a private PAM fixture. `wl-paste` verifies interoperability and
`grim` supplies independent screenshot references only in tests. All eight
output transforms and fractional-scale crops are compared against actual PNGs.
The mathematical transform conventions were cross-checked against upstream
[grim rendering](https://github.com/emersion/grim/blob/master/render.c) and
[output transforms](https://github.com/emersion/grim/blob/master/output-layout.c).

See [T14 evidence](../artifacts/t14/README.md) for exact tested binaries and
results. Native hardware HDR/color, very large displays, real screen-reader
interaction and an isolated-window capture client remain outside this validated
slice. No host clipboard, output, PAM policy, power state or portal service is
mutated by the tests.
