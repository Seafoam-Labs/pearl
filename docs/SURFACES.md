# Output surfaces and control (T05)

Session mode now owns desktop surfaces on the verified Aqueous display. The
wallpaper, bar, modal popup, OSD and invisible frame are primitives for T06 and
later services. The bar currently has one Pearl button; the popup has a title,
explanatory text and Close button. There is no application launcher, complete
control center, audio service or persistent surface configuration yet.

## Identity and ownership

`src/core/application.zig` owns the T04 adapter, surface manager and control
server, in that teardown order: close control, destroy surfaces, stop adapter.
The adapter's paired IPC hello must agree with the `session` from
`aqueous_shell_manager_v1.capabilities` on **GTK's actual Wayland connection**.
The native manager is destroyed after reading identity; it does not subscribe
or send mutations. A mismatch exits before mapping surfaces or claiming control.
An initial five-second deadline prevents an unverified session from hanging.

`src/ui/surfaces/manager.zig` reconciles live enabled/powered output records with
valid `GdkMonitor` connector names. It requires one exact match, retains the
monitor, and copies runtime IDs. It supports at most 16 mapped outputs. IPC and
monitor notifications schedule one coalesced GLib idle callback; idle state has
no repeating timer. Disable/removal destroys the affected surfaces and dismisses
its popup/OSD. Re-enabling creates fresh surfaces. IPC unavailability clears all
surfaces and control; the adapter's normal recovery supplies fresh state.

GTK stays on the creating GLib thread. Each stable allocated surface owns its
window reference, native effect and signal connections. Native GDK surfaces and
frame clocks have explicit references and tolerate GTK disposing them during
hotplug. Unmap/unrealize destroys the effect; remap binds the new native surface.
`policy.zig` contains the pure reservation and popup geometry rules.

## Surface policies

All dimensions are logical pixels. GTK handles buffer scaling. Output and
usable bounds from Aqueous are global; popup status coordinates are output-local.
Negative origins and rotation do not introduce another scale multiplication.

| Primitive / namespace | Layer | Exclusive zone | Keyboard / input |
| --- | --- | --- | --- |
| Wallpaper / `pearl:wallpaper` | background | -1, fills output without reserving space | none / empty |
| Bar / `pearl:bar` | top | measured thickness, default 48 at top | none / rounded panel only |
| Popup / `pearl:popup` | overlay | 0 | exclusive while visible / usable-area backdrop |
| OSD / `pearl:osd` | overlay | 0 | none / empty |
| Frame / `pearl:frame-exclusion` | top | configured strip thickness | none / empty |

One bar per output may occupy any edge. A frame may reserve each other edge;
bar/frame conflicts return `EdgeOccupied` without changing the reservation.
Frames default to zero and use a transparent texture to ensure GTK attaches a
buffer: an empty transparent box alone may never map. No full-screen invisible
reservation surface intercepts desktop input. Killing Pearl releases all zones
through normal Wayland client destruction.

There is one popup across all outputs. Showing a new target replaces it. It is
centered and clamped inside the target's usable bounds, including updates after
reservation/rotation changes. Escape, Close and a backdrop click dismiss it.
The dismissal click is consumed; the next click can reach the application below.
This primitive deliberately uses modal keyboard focus. Future nonmodal menus
must explicitly choose their own focus policy. OSD is a single replaceable,
expiring display (default two seconds) that neither takes focus nor handles
pointer input. Locked state dismisses popup/OSD and rejects control mutations.

## Native background blur

`src/platform/wayland/effects.zig` uses pinned generated Zig Wayland bindings and
Ghostty's `gdkwayland4` accessors. It borrows GTK's display and actual rendered
`wl_surface`; it opens no second display, performs no socket read/dispatch or
roundtrip, and never attaches or commits a GTK buffer. GTK dispatches its
registry listeners on the default queue.

Bar, popup and OSD request rounded, surface-local blur regions through
`ext-background-effect-v1`. An after-paint callback observes actual panel
allocation. Changes update blur/input regions and queue one GTK draw for the
next double-buffered commit. Unchanged geometry produces no extra frame. The
capability event controls background alpha: unavailable/disabled effects use
opaque panel tokens. Global removal destroys owned effect objects. Wallpaper
and frame surfaces never request blur.

Pearl does not write Aqueous rules or set global widget opacity. A native request
on a main layer surface needs no enabling rule; the compositor still applies
an explicit namespace veto. `pearl:popup` is a main overlay layer surface, **not
an XDG popup**. GTK-created XDG popovers receive no blanket blur inheritance:
Aqueous's `blur` plus `blur_popups` policy remains authoritative. The protocol
does not report individual rule vetoes to Pearl, so `status.blur` reports the
global native capability, not whether every panel's effect is allowed.

See [binding inputs and regeneration](../bindings/protocols/README.md).

## pearlctl and control v1

`zig build` installs `pearl` and `pearlctl`. Run the CLI in the same Aqueous
environment as the intended shell. It performs a fresh same-UID Aqueous hello
and derives `$XDG_RUNTIME_DIR/pearl/<session>/control.sock`. There is no endpoint
override, directory discovery, D-Bus activation, global instance name or replay.
The server additionally checks the session and normalized Wayland display path.
A mixed parent/nested environment fails rather than controlling the parent.
A deliberately supplied complete environment identifies that session; this is
session routing, not a security boundary against another process of the same UID.

The server validates private owned mode-0700 directories, accepts same-UID peers,
and holds an exclusive `instance.lock`. Only its owner removes a stale socket.
The lock inode stays on disk across shutdown to prevent locking different inodes.
A second Pearl exits `AlreadyRunning` without disturbing the original endpoint.
A restart after SIGKILL safely reclaims its stale socket.

```sh
pearlctl status
pearlctl popup show --output OUTPUT_ID
pearlctl popup toggle                    # unique seat's current output
pearlctl popup hide
pearlctl bar set --output OUTPUT_ID --edge bottom --size 64
pearlctl frame set --output OUTPUT_ID --edge top --size 8
pearlctl frame set --output OUTPUT_ID --edge top --size 0
pearlctl osd show --text 'Sound muted' --duration 1200
pearlctl quit
```

Use opaque IDs from `status.outputs[].id`; do not persist them between sessions.
Bar sizes are 32–160; frame sizes 0–160; OSD text is 1–512 UTF-8 bytes and duration
100–10000 ms. Missing popup/OSD output uses the unique seat; ambiguous seats fail.

Control uses one flat JSON request and reply per Unix stream connection, each
LF-terminated with at most 8192 payload bytes. Version `pearl:1` is independent
of Aqueous `ipc:1`. There are at most eight active clients, each with a five-second
deadline including partial requests and blocked replies. Nested JSON, duplicate
or unknown fields, wrong types, unknown operations and invalid values fail.
Oversized frames and excess clients are disconnected. Required request fields:

```json
{"pearl":1,"id":"7","session":"0123456789abcdef0123456789abcdef","display":"/run/user/1000/wayland-1","op":"popup_show","output":"OUTPUT_ID"}
```

| Operation | Additional fields |
| --- | --- |
| `status`, `quit`, `popup_hide` | none |
| `popup_show`, `popup_toggle` | optional `output` |
| `bar_set`, `frame_set` | required `output`, `edge`, `size` |
| `osd_show` | required `text`; optional `output`, `duration_ms` |

Success is `{"pearl":1,"id":"7","ok":true,"result":{"applied":true}}`.
`applied` means the surface change was queued on GTK's thread; the compositor
may deliver geometry afterwards. `status` returns session, adapter availability,
global blur capability, mapped outputs, popup and OSD state. Each output contains
connector, scale, global bounds/usable bounds, bar edge/measured size and frame
sizes in **top, right, bottom, left** order.

Failure is `{"pearl":1,"id":"7","ok":false,"err":{"code":"EdgeOccupied"}}`.
Stable server codes are `Version`, `InvalidRequest`, `StaleSession`,
`DisplayMismatch`, `Unavailable`, `OutputUnavailable`, `Locked`, `AmbiguousSeat`,
`EdgeOccupied`, `InvalidSize`, `ResponseTooLarge` and `Internal`. Unparseable
requests use ID `"0"`; validated requests echo their decimal string ID. Clients
must tolerate future error codes. `quit` stops Pearl after the reply drains.

CLI exit codes: **0** success, **2** usage, **3** connection/environment failure
or unknown completion, **4** server rejection. Successful connections print the
server's JSON. Local connection errors also print an error JSON (without request
ID); launch/usage errors print stderr. If a request may have been sent but its
reply is lost, the CLI reports `UnknownCompletion` and never retries a mutation.
`--help` and `--version` work without a display or GTK initialization.

## Reproduce validation

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test test-bindings test-adapter-unit -Doptimize=ReleaseSafe
python3 scripts/check-wayland-bindings.py
zig build test-surfaces -Doptimize=ReleaseSafe
```

The surface suite needs Python/Pillow, `dbus-daemon`, `grim`, `wlrctl`, `wtype`,
`wlr-randr`, the T00 private no-effects compositor and a Vulkan-effects build.
All buses, outputs, input injection, config reloads and parent/nested displays
belong to temporary sessions. Test rule edits never reach user configuration.
Default evidence is [artifacts/t05/latest](../artifacts/t05/latest/results.json).
Override the effects binary with `-- --effects-aqueous /path/to/aqueous`.

The tested effects build used Aqueous revision
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480` and its patched wlroots:

```sh
PKG_CONFIG_PATH=/home/zoey/RiderProjects/Aqueous/compositor/.deps/wlroots-render-hook/lib/pkgconfig \
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" \
zig build --build-file /home/zoey/RiderProjects/Aqueous/compositor/build.zig \
  --cache-dir "$PWD/.cache/aqueous-effects-build" \
  --prefix "$PWD/.cache/aqueous-effects" \
  -Dvulkan-effects=true -Dman-pages=false -Doptimize=ReleaseSafe -Dllvm
```

Adapt the source paths for another checkout. These flags produce test binaries
in Pearl's ignored cache, without modifying the reference source or host session.
The blur test uses Aqueous Vulkan on an NVIDIA RTX 5090, GTK cairo buffers, and
`grim` captures. It compares the same popup over a static gallery with native
blur, a namespace veto, and the restored rule; then checks capability disable,
opaque fallback, re-enable, region resize and repeated remapping in the protocol
trace. Rule tests await Aqueous's actual one-second configuration monitor reload.

Physical display unplug/DPMS/resume, other GPUs, HDR/VRR and accessibility remain
release-gate checks. Private Vulkan compositor teardown logs a wlroots
`shared_buffer_finish: 1 allocations left` diagnostic; Pearl exits cleanly under
fatal GTK warnings, but this test does not establish compositor allocation
cleanup or production GPU performance.
