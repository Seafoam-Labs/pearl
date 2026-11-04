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
clipboard service, or portal ownership change. Text history is saved by Pearl's
own worker; PNG images remain memory-only.

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
| Retention | Seven days from the last successful copy, refreshed by recopy |
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

Pearl saves accepted text automatically. With an absolute `XDG_STATE_HOME`, the
file is `$XDG_STATE_HOME/pearl/clipboard/history.bin`; otherwise it uses
`$HOME/.local/state/pearl/clipboard/history.bin`. The `pearl/clipboard`
directories must be private (`0700`), and the history file and writer lock
use `0600`. The versioned file stores UTF-8, timestamps and copy order, but
no PNGs or runtime entry IDs. Its SHA-256 checksum detects corruption;
**the contents are plaintext, not encrypted**.

Successful copies renew an entry's seven-day lifetime, including copies of
existing eligible entries. Timestamps and the seven-day comparison use whole
Unix seconds; an entry expires when its age is at least 604800 seconds.
Expiration is lazy: copying/capturing, opening or reading history, selecting an
entry and Delete prune expired rows before they can be returned or reused.
Multiple expired text rows share one durable removal barrier, combined with
the copy or Delete where possible. If admission is Busy or preparation fails,
expired history is withheld until a later activity can retry. Clear removes
everything directly without an expiration scan. Idle history may retain expired
rows in memory and on disk; there is no history polling or expiration timer.

On the first eligible unlock Pearl automatically loads saved history
asynchronously, without requiring the panel to open. It restores only eligible
saved text, without publishing it to the current
Wayland selection or importing a pre-existing selection. The model uses
wall-clock time plus elapsed boot time to avoid reversing expiry in one
session. If the saved clock floor is more than five minutes ahead of the
startup wall clock, history is withheld instead of changing saved timestamps.

`src/services/clipboard.zig` remains the GTK-context Wayland service.
Supporting Zig modules under `src/services/clipboard/` own history, time,
the plaintext codec, storage, one background writer, coordination and status
presentation. Filesystem reads, writes and synchronization run on the worker.
The worker sleeps on its condition when there are no jobs. Startup, save and
removal completion, errors and drained shutdown signal a nonblocking Linux
eventfd. A GLib I/O watch observes the wakeup and reads worker state on the main
context; the worker never calls GTK or Wayland. Notifications can coalesce, but
required removal jobs cannot. The main-context watch is detached before its
callback context or the worker descriptor is released, so queued or late
wakeups cannot access freed objects. Shutdown uses this same notification,
without a drain polling timer.
Pending ordinary saves may be superseded, but removals stay ordered. A Delete
or Clear is confirmed only when its worker receipt is `durable`, not when
the request is queued. Removals also delete validated temporary snapshots left
by interrupted saves before confirming durability, including when text remains
in the history file.

Unsafe, corrupt or unsupported files are not overwritten automatically.
When a safe history file is corrupt or has an unsupported version, an unlocked
user can explicitly run `pearlctl clipboard clear` and poll its removal receipt.
Clear revalidates the rejected file under the exclusive writer locks, removes
validated temporary snapshots and synchronizes the directory. After a `durable`
receipt, restart Pearl to resume clipboard history. Other storage failures and
untrusted clock state remain fail-closed; a privacy lock still denies Clear.
Storage or clock failures currently disable Pearl's history collection and
selection rather than falling back to memory-only history. Verify that the
state directory works on Devario. Saved plaintext may remain in backups or
filesystem snapshots; Delete and Clear do not promise forensic erasure.

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
**Locking does not delete saved or in-memory clipboard history.** The status
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
pearlctl clipboard status --operation TOKEN --instance INSTANCE
pearlctl clipboard show --output OUTPUT_ID
pearlctl clipboard toggle --output OUTPUT_ID
pearlctl clipboard select --generation ENTRY_ID
pearlctl clipboard delete --generation ENTRY_ID
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
reject stale traversals. A full response, including framing and newline, fits
8192 bytes, so pages can contain fewer than 20 previews. Delete and Clear
return admission separately from durable completion. Check the returned token
with `clipboard status --operation ... --instance ...`: `pending`, `busy`,
`failed` and `uncertain` do not mean `durable`. Optional `--instance` guards
also apply to Delete/Clear. Explicit operation queries remain available after
storage failure while the privacy gate is open; history stays hidden. Locking,
suspension and shutdown still deny receipt access. An accepted removal returns
its token even if the worker fails before the initial response is produced.

Capture requests acknowledge queueing, not completion. Wait for `pending: false`
and an increased `generation`; inspect the message if it did not increase.
Copy/save reject stale generations. There is no clipboard payload argument in
control requests and no bulk payload in status responses.

## Validation and boundaries

```sh
zig build test -Doptimize=safe -j2
zig build test-clipboard-completion -Doptimize=safe -j2
zig build test-clipboard-history -Doptimize=safe -j2
PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-master" ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-clipboard-capture test-capture-master -Drelease=true -Doptimize=ReleaseSafe
python3 scripts/check-wayland-bindings.py
```

Compositor-free tests use injected seconds for lazy expiry, recopy, batched
removals and Busy/allocation failures. The GLib completion suite checks startup,
saves, removal receipts, failures, shutdown, idle dispatch and detaching a watch
before queued or late notifications. These tests demonstrate the absence of
recurring clipboard maintenance; they do not measure a CPU or latency reduction.
The history service regressions also verify synchronous invalidation and
nonrecursive notification on successful expiry, Busy and allocation failures.
Widget regressions cover filtering/navigation across expiry, unchanged-cache
reuse, failed-maintenance redaction and preservation of lock privacy. They use
injected timestamps and a synthetic worker, never the desktop clipboard; the
two widget tests are skipped when GTK cannot open a display.

The suite uses private Aqueous outputs, D-Bus services, generated-Zig clipboard
producers and a private PAM fixture. `wl-paste` verifies interoperability and
`grim` supplies independent screenshot references only in tests. All eight
output transforms and fractional-scale crops are compared against actual PNGs.
The mathematical transform conventions were cross-checked against upstream
[grim rendering](https://github.com/emersion/grim/blob/master/render.c) and
[output transforms](https://github.com/emersion/grim/blob/master/output-layout.c).

Current evidence lives in `artifacts/aqueous-master/functional/test-capture-master`
and `test-clipboard-capture`; earlier `artifacts/t14` remains historical. The
master suite compares eight transformed outputs against independently captured
color-corrected references and proves that an undescribed isolated source cannot
leave a PNG ready. Hardware HDR, isolated scene pixel/color correctness after an
upstream metadata fix, very large displays and real screen-reader interaction
remain unaccepted. No host clipboard, output, PAM or portal service is mutated.

### Devario persistence acceptance (2026-11-02)

**Passed for the cases below on an installed Devario/Aqueous desktop**, using
the private `feat/clipboard-persistence` branch at
`ce340952ffa5f3fe23326e67b1cd8274d1206eaa`. The production Zig
0.17.0 build and `zig build test -Doptimize=safe -j2` succeeded with
GTK 4.24.1 and gtk4-layer-shell 1.3.0.

The development `zig-out/bin/pearl` ran as the real
`aqueous-pearl.service` through a temporary runtime-only systemd drop-in,
preserving Devario's `/usr/bin/aqueous-activity-launch` wrapper.
`XDG_STATE_HOME=$HOME/.local/state/pearl-persistence-test` isolated the
test data from the ordinary desktop state. The effective development
executable, state environment, `0600` history file and `0700` clipboard
directory were verified before testing.

| Installed-session check | Observed result |
| --- | --- |
| Text capture and durability | Text saved with healthy `durable` state; marker present after a Pearl restart |
| Single-entry Delete | Receipt reached `durable`; deleted marker absent after restart |
| Clear | Receipt reached `durable`; zero entries immediately and after restart |
| PNG volatility | One PNG recorded in memory; zero PNGs restored after restart |
| Lock privacy | Real Aqueous lock acquired; CLI hid history entries, counts and identifiers; saved text remained available after unlock |
| Copy during lock | Compositor accepted synthetic text while locked; the marker was absent when all 16 visible history records were checked after unlock |
| Unlock clipboard ownership | A Pearl-owned synthetic selection was verified before locking and was not republished on unlock |
| Capacity and duplicate recopy | 105 unique copies retained the newest 100 and evicted the oldest five; duplicate recopy promoted its original ID without increasing the count |
| Per-entry text bound | 262,144-byte text accepted; 262,145-byte selection rejected without changing history; subsequent collection and durability remained healthy |
| Aggregate payload bound | 64 distinct 262,144-byte entries exactly filled 16,777,216 bytes; the 65th evicted the oldest; all 64 retained entries and bytes survived restart |

A first aggregate stress-test attempt timed out in the Python harness because
it captured `wl-copy` stderr across the clipboard owner's background lifetime.
Redirecting stderr to `DEVNULL` resolved the harness issue; the corrected
aggregate test passed. A separate unlock-detection script exceeded its
60-second observation window, but subsequent checks confirmed the compositor
unlocked, clipboard access resumed, and the lock-time copy was absent; an
independent no-republish lock/unlock run also passed.

**Expiry scope:** The successful Zig test suite includes deterministic
seven-day expiry, recopy lifetime refresh, restoration/pruning and
clock-untrusted cases with injected timestamps. A real seven-day elapsed-time
run on the Devario desktop was **not** performed, and the host clock was not
modified. This acceptance records the listed manual integration cases, not a
claim of exhaustive hardware, failure-injection or long-duration qualification.

**Cleanup and rollback verified:** After testing, the isolated history was
explicitly Cleared with a `durable` receipt and zero entries. The temporary
systemd drop-in was removed, the user daemon reloaded and
`aqueous-pearl.service` restarted successfully. The final process executable
was `/usr/bin/pearl`, the effective launch command was
`/usr/bin/aqueous-activity-launch /usr/bin/pearl`, and `DropInPaths` was
empty. The installed Pearl package was not replaced. The development checkout
remains available separately for further work.
