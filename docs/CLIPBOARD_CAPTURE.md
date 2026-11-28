# Clipboard and screenshots

The **Clipboard & capture** panel opens screen-centered, like the launcher, and
follows the same Material and native GTK appearance paths. Open it from the
`clipboard` bar item, with `pearlctl clipboard toggle` or `clipboard show`, or
with `pearlctl capture show` for the screenshot tab. New default bar groups
include the item; existing explicitly configured groups remain authoritative.
Use the Settings bar-group fields to add `clipboard` to an existing setup.

The panel ignores `popup.placement` and is always centered; opening it puts
focus in the history filter. A second `clipboard toggle`, Escape or a backdrop
click closes it. Opening it while another pane is shown replaces that pane.
Pearl never grabs key combinations: an Aqueous keybinding that runs
`pearlctl clipboard toggle` is what makes this a clipboard shortcut.

## History navigation

| Input | Effect |
| --- | --- |
| Typing | Case-insensitive substring filter over previews; Enter acts on the first match |
| Up / Down | Move the selection and scroll it into view |
| Enter, or one click on a row | Publish the selected entry, move it to the top of the list, and close the panel |
| Delete | Remove the selected entry without publishing it |
| Escape | Dismiss the panel; it never edits the filter |
| Row **Copy** / **Delete** | Same as Enter and Delete, for pointer use |

Publishing replaces Pearl's selection; pasting stays an action in the
destination application. A copied entry is promoted to most-recent, so a value
still in use is the last one eligible for eviction. Tab reaches **Clear
history**, the Capture tab and the capture controls; the in-row buttons are
pointer conveniences over the same Enter and Delete actions. An empty filter
result keeps history intact and says so in place of the list.

## Clipboard contract

Pearl uses generated **ext-data-control-v1** bindings on GTK's Wayland connection.
GTK remains the only reader of that connection. There is no wl-copy/wl-paste
production dependency, synthetic typing, primary-selection history, D-Bus
clipboard service, or portal ownership change. Text history is saved as JSON;
PNG images remain memory-only.

The regular selection accepts UTF-8 `text/plain;charset=utf-8` (or `text/plain`)
and `image/png`. PNG takes precedence when both image and text are offered.
Other formats, NUL-containing or invalid UTF-8 text, empty/truncated payloads,
and oversized payloads are rejected. A disappeared owner can leave already
received history intact; selecting an entry creates a fresh data-control source
with its own retained payload and promotes that entry to most-recent. Paste
remains an action in the destination app. Deleting a history entry does not
interrupt an already selected payload or an in-progress paste. Clear releases
Pearl's current selection as well as history; it does not erase a selection
owned by another application.

| Resource | Bound |
| --- | --- |
| Retained entries | 100 across text and PNG; an exact duplicate is promoted, not added again |
| Retained payload total | 16 MiB |
| Text per entry | 256 KiB |
| Retention | Seven days from the latest copy or selection |
| After restart | Eligible text restored; PNG images are never persisted |
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

The [launcher calculator](DESKTOP.md#calculator) publishes plain text through
this same service. Enter or clicking a result copies only the displayed number.
The service resolves duplicate history entries by identity, promoting an
existing match to most-recent, and retains the selected payload independently
of the launcher, so a paste remains available after the popup closes. If
selection publication cannot start, the old selection and the history order are
preserved and the launcher stays open for retry. Expressions are not retained
as calculator history, and a pending copy is never replayed after unlock.

## Persistent text history

Text is saved to `$XDG_STATE_HOME/pearl/clipboard.json`, normally
`~/.local/state/pearl/clipboard.json`, as an array of `{text,last_used}` records.
The Pearl state directory must be private (`0700`); snapshots use `0600` and
atomic replacement. The contents are **plaintext, not encrypted**. PNGs and
runtime entry IDs are never serialized. Unsafe files, symlinks and permissions
are rejected rather than repaired automatically.

On the first eligible unlock, saved text is loaded with its original timestamps
and order. Restoring history never publishes a clipboard selection. Missing
files start empty. Malformed or oversized JSON is rejected without overwriting
it merely because loading failed. A later successful mutation can save a fresh
snapshot. Equal-time entries retain their saved order.

An entry expires seven days after its latest copy or selection, at an age of
604800 whole Unix seconds. Copying a duplicate promotes the same entry and
refreshes its lifetime. Expiry is checked during history access and mutations,
including filtering or navigating an already-open panel. This is activity-driven
cleanup, **not a background deletion deadline**; an idle file can retain expired
bytes until a subsequent operation. Existing byte limits can evict entries sooner.

Saves run synchronously on GTK's main context and are best effort. Storage errors
are logged without clipboard contents. Capturing, copying and pasting remain
usable when storage fails. PNG-only history changes avoid writes unless they
also remove text or retry a previously failed text save. Slow storage can delay
an event dispatch.

Delete and Clear remove entries from memory immediately, then attempt to save.
A `SaveFailed` response means persistence was not confirmed; the panel explains
that removed entries may return after restarting. An error can occur after the
new file was renamed into place, so failure does not establish that disk stayed
unchanged. Clear can retry even when history is already empty. A successful
retry clears the dirty/error state. Shutdown frees runtime resources without
saving an accidental empty history. Delete/Clear do not promise forensic erasure
from backups, filesystem snapshots or interrupted private temporary files.

Legacy `$XDG_STATE_HOME/pearl/clipboard/history.bin` files are left untouched;
they are neither migrated nor read as a fallback. Clear affects JSON history only.

## Privacy and lock integration

Selections advertising `x-kde-passwordManagerHint`,
`application/x-keepassxc`, or `application/x-pearl-private` are excluded regardless
of the hint's contents. Hints are advisory: unmarked secrets cannot be
distinguished from ordinary text and may be saved as plaintext.

Lock requests, authoritative Aqueous lock state, sleep preparation, inactive or
unavailable session state, mismatched native/IPC session identities, and Pearl
polkit prompts suspend clipboard and capture access. Pearl cancels transfers,
hides retained clipboard history in the panel and CLI, clears screenshot
previews, releases its own selection, and disconnects data-control collection.
**Suspension retains hidden text history and discards PNG history from memory.**
This also applies to device/manager/seat loss and ambiguous-seat suspension.
Lock/unlock does not refresh text timestamps. The status
response exposes no retained entries, IDs, counts, timestamps or paging tokens
while suspended. Reconnecting skips the initial selection, so text copied while
locked is not collected on unlock. Unlock never automatically republishes an
old clipboard item or a cancelled calculator copy.

Buffers explicitly owned by these services are zeroed before release. This is
not a promise to erase copies held by other applications, GTK, the compositor,
the allocator's prior reallocations, or the operating system. PNG decode and
clipboard re-encode have bounded input/output dimensions and run in the main
context; unusually expensive valid PNGs can delay a dispatch. Screenshot pixel
conversion and encoding use one cancellable worker with an application hold.

## Screenshot contract

The current-master path uses generated **ext-image-copy-capture-v1** and
output/foreign-toplevel source managers v1, with **aqueous-capture-color-v1**
per-frame metadata on GTK's Wayland connection. XML and generated output hashes
are pinned in `bindings/protocols/inputs.json`. No C bridge is used. The older
screencopy v3 path is retained only when native output-source interfaces are absent;
a native capture failure does not silently fall back.

Pearl accepts 8-bit XRGB/ARGB/XBGR/ABGR shared-memory formats, with 8192 per axis,
8,388,608 pixels and 40 MiB allocation limits. Current-master captures require
sRGB primaries and described sRGB or gamma-2.2 transfer. Gamma-2.2 pixels are
converted to sRGB before PNG encoding. Unavailable metadata, HDR transfer,
wide-gamut encoding and unsupported formats produce an explanation without PNG
export. Bit depth alone is not interpreted as a color space.

There is one capture in flight, a 200 ms preparation delay, and a five-second
frame deadline. The panel's capture action hides the panel before requesting a
frame and reports completion through the OSD; `pearlctl capture show` reopens it
on this tab to preview, save or copy, while `clipboard show` and `clipboard
toggle` reopen it on history with focus in the filter. A worker normalizes output rotation/reflection and the protocol's
Y-invert flag. Output removal or geometry/mode/scale change cancels the target.
A cancelled worker cannot publish its result after a lock or target change.
An accepted new capture clears the previous screenshot before requesting pixels;
a failed source cannot leave an unrelated old image ready to save. A returned output is resolved again through its current
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
connector and crop rectangle, for that successful capture. The
outward crop includes partially covered edge pixels. It is confined to one
output, independent of that output's desktop origin. The current UI accepts an
explicit rectangle; a pointer-drag region selector is not included.

The isolated-window selector uses exact current foreign-toplevel identities,
bounded to 256 windows with paginated CLI enumeration. A closed source is removed
and its ID cannot select a replacement window. Pearl requests the actual native
window source even when unrelated windows overlap; it never substitutes a crop.
`isolated_window` reports source availability; `image_isolated` describes a
successful retained image. Source availability does not promise export: pinned
Aqueous currently reports unavailable color metadata for scene/window sources,
so Pearl withholds their PNG and explains why. See
[AQUEOUS_MASTER_DEPENDENCIES.md](AQUEOUS_MASTER_DEPENDENCIES.md).
Installed portal screenshots and screensharing retain their existing ownership.

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
pearlctl clipboard status --offset 20 --limit 20
pearlctl clipboard status --offset 20 --limit 20 --revision REV --instance INSTANCE
pearlctl clipboard show --output OUTPUT_ID
pearlctl clipboard toggle --output OUTPUT_ID
pearlctl clipboard select --generation ENTRY_ID --instance INSTANCE
pearlctl clipboard delete --generation ENTRY_ID --instance INSTANCE
pearlctl clipboard clear

pearlctl capture output --output OUTPUT_ID
pearlctl capture region --output OUTPUT_ID --text 31,41,203,117
pearlctl capture windows
pearlctl capture windows --offset 32
pearlctl capture window --text FOREIGN_TOPLEVEL_ID
pearlctl capture status
pearlctl capture show
pearlctl capture copy --generation SCREENSHOT_GENERATION
pearlctl capture save --generation SCREENSHOT_GENERATION
pearlctl capture save --generation SCREENSHOT_GENERATION --path /absolute/new.png
pearlctl capture cancel
```

Clipboard status defaults to at most 20 previews per page. `total`, `returned`,
`has_more` and `next_offset` expose all 100 entries; `revision` and `instance`
reject stale traversals. The complete response, including framing and newline,
fits 8192 bytes. Select and Delete require the `instance` returned alongside the
entry ID. Missing/malformed instances fail request validation; a different
instance returns `StaleInstance` before the action. IDs can be reused after a
restart, so callers must retain the matching instance. Clear accepts an optional
instance guard.

Delete/Clear complete synchronously. Their `SaveFailed` error can accompany an
already-applied in-memory removal, as described above. Status exposes `dirty`
and `persistence_error` while access is open; storage errors do not make native
clipboard access unavailable. Suspended status hides retained content and paging
metadata. There are no persistence operation tokens or completion queries.

Capture requests acknowledge queueing, not completion. Wait for `pending: false`
and an increased `generation`; inspect the message if it did not increase.
Copy/save reject stale generations. There is no clipboard payload argument in
control requests and no bulk payload in status responses.

## Validation and boundaries

```sh
zig build -Doptimize=safe -j2
zig build test -Doptimize=safe -j2
zig build test-clipboard-history -Doptimize=safe -j2
python3 scripts/test.py check-registry --python-only
```

Use Zig 0.17.1. The registered `test-clipboard-history` target checks controlled-clock
expiry, JSON and payload bounds, private atomic saves, restart restoration,
unsafe storage, save failures, paging and suspension callbacks. It uses disposable
state directories and socket pairs, without accessing desktop clipboard history.
GTK widget tests require `PEARL_TEST_CLIPBOARD_GTK=1` and an explicitly isolated
display, such as a private Broadway server with `GDK_BACKEND=broadway` and a
private `XDG_RUNTIME_DIR`.
They otherwise report skips and never use an inherited desktop display.

The `test-clipboard-capture`, `test-launcher-calculator`,
`test-security` and `test-capture-master` targets use the pinned private Aqueous
fixture from `scripts/aqueous-target.json`, isolated XDG directories and D-Bus/PAM
fixtures. The harness supplies private user and system autostart roots to Pearl's
test build; isolated XDG directories alone do not override its system autostart
directory. `wl-paste` checks real paste and screenshots check transforms and crops.
Run these suites only with verified fixtures and autostart isolation, never against
the installed desktop. Build and headless passes do not establish compositor acceptance.

Reported manual Devario acceptance covers JSON persistence/restoration, duplicate
promotion, Delete/Clear persistence, screenshot-to-PNG copy, lock/unlock privacy
(text retained, PNG discarded), 100-entry retention after 105 copies, 20-entry CLI
pages, and the text, PNG and retained-payload limits. These are manual results,
separate from automated checks. Real Wayland verification remains for controlled-clock
seven-day expiry, exact PNG dimension boundaries and unexpected device-loss recovery.
Hardware HDR and screen-reader interaction also need dedicated validation.
