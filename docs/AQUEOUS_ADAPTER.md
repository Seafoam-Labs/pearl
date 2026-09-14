# Persistent Aqueous adapter (T04)

Session mode now connects to the inherited Aqueous IPC endpoint. The demo gallery
continues to use fixtures. This adapter supplies the state and actions needed by
T05 surfaces and T06 widgets; it does not introduce a shell control endpoint.

## Ownership and API

`src/aqueous/client.zig` owns the model, two transports, action queue, deadlines
and icon cache. `commands.zig` defines typed actions and policy validation.
`transport.zig` uses Ghostty's generated GIO/GLib bindings directly. `icons.zig`
decodes the protocol's bounded RGBA PNGs in Zig and wraps the resulting pixels
using generated GdkPixbuf bindings. There is no C bridge or decoder subprocess.

Create `Client.init(endpoint, runtime, context, observer)`, move it to its final
address, then call `start()`. Keep that address stable through `deinit()`. All
methods and observer calls belong to the same GLib main context. `stop()` removes
socket/deadline sources synchronously, resolves pending tickets and clears state;
`deinit()` additionally releases storage. The GTK application stops the adapter
before destroying its window. The adapter does not create worker tasks.

The observer receives availability, state, command completion, icon-change and
fault events. Arguments and model pointers are borrowed. Read state during a
callback; schedule mutating operations for a subsequent main-context turn rather
than reentering the adapter. A successful model update invalidates old entity
pointers. Cached pixbufs are borrowed until eviction, metadata change, disconnect
or shutdown; retain a GObject reference if a widget needs a longer lifetime.

Use `availability == .ready` before displaying actionable state. Readiness requires
matching hello sessions, a successful subscription, an atomically installed
snapshot and its matching acknowledgement reply. Observation remains available
while locked or in a compositor mode that disables commands. Global capabilities
alone do not imply an action is allowed: `commands.validate()` also checks the
current session, target and seat policy.

`enqueue(Action)` returns a local ticket or an immediate validation/queue error.
For example, `.{ .workspace_activate = .{ .id = workspace.id, .seat = seat.id } }` activates a runtime workspace ID. Workspace
numbers, connector names and titles are not IDs. The adapter copies action strings;
callers may release them after enqueue returns. The 32 queued actions are separate
from the one request already outstanding. Validation runs again at dispatch.

Completion status has these meanings:

| Status | Meaning |
| --- | --- |
| `applied` | Server committed the command at the returned sequence. The event stream may reach it later. |
| `accepted` | Server accepted close/exit. This does not prove window destruction or session termination. |
| `rejected` | Dispatch validation or a matching server error rejected the action. `detail` gives the reason. |
| `dropped` | Queued work was invalidated, or the transport failed before any command bytes were sent. |
| `unknown` | Some command bytes were sent but no valid completion was received. Never replay automatically. |

Commands never optimistically edit the model. Even a `stale_session` error is an
explicit rejection of its ticket, followed by reconnection and dropping old work.
A locally oversized command is rejected without breaking a healthy connection.

## Wire state and recovery

Both sockets are nonblocking AF_UNIX streams. The inherited endpoint must be a
normalized path under `$XDG_RUNTIME_DIR/aqueous/<instance>/ipc.sock` and fit the
Unix socket address. GIO peer credentials must report this process's UID; a
credential-query failure rejects the connection. Reconnect never reads a new
environment, scans a runtime directory, invokes a subprocess or discovers another
instance. A newly advertised endpoint requires relaunch.

The request socket performs hello, mutations and optional icon fetches. The event
socket performs hello, subscribe and exact delivery acknowledgements. Each permits
one outstanding request. IDs are decimal strings from one increasing u64 counter
shared by both sockets (therefore increasing on each); they are never reused,
even after reconnect. Overflow requires a new client. Session-scoped entity and
sequence strings remain unchanged.

The existing T02 codec enforces UTF-8, NDJSON, frame/batch/depth bounds and atomic
model validation. Each socket honors its negotiated limits; model storage uses
the smaller advertised state limit. Short writes retain their offset and add an
OUT source only while data remains. Reads process at most 256 KiB per source
callback to let the main context run other work. Invalid ordering, reply IDs,
sessions, delivery acknowledgements, repeated snapshots or discontinuous deltas
invalidate both connections before any more actions can dispatch.

One-shot GLib sources use absolute monotonic deadlines: five seconds for connect,
hello and each request; eight seconds from subscribe dispatch through initial
snapshot acknowledgement. Progress does not extend these deadlines. Healthy idle
connections have neither a timer nor heartbeat traffic. Disconnect retries use
250 ms exponential backoff, capped at 8 seconds, plus up to 25% jitter (10 seconds
maximum actual delay). A completed initial acknowledgement resets backoff.

Socket and timer callback tokens carry generations. Destroying sources invalidates
their tokens; callbacks copy tokens before an operation can destroy/rearm their
current source. A broken channel invalidates the model and clears both queues and
the cache. Recovery installs a fresh snapshot before exposing actions again.

## Window icons

Call `icon(.{ .id = window.id, .revision = metadata.revision, .size = logical_size,
.scale = integer_scale })` only when metadata advertises pixels. It returns a
borrowed cached pixbuf, or null while queued/unavailable. The observer announces
completed cache entries. `icon_metadata` and `icon_fetch` are optional capabilities;
locked sessions cannot fetch icons. A named application icon is the future UI
fallback when no pixels are available.

Keys include window, revision, size and scale, within a session-local cache that
is cleared on reconnect. Stale metadata is pruned after every state update and
checked again at completion. Queued user actions always precede queued icon
fetches; an already sent fetch keeps its normal five-second deadline.

There are at most 16 pending icon entries and 32 cached entries, including negative
results. Old completed entries are evicted first. Decoded pixel storage is at most
8 MiB: 32 images of at most 256 × 256 × 4 bytes. Base64 is capped at 512 KiB. PNG
headers must match requested dimensions and the protocol's non-interlaced,
eight-bit straight RGBA format. The decoder validates chunk CRCs and zlib Adler32,
implements all five scanline filters, supports multiple IDAT chunks, and rejects
output beyond the expected scanline size using a fixed 32 KiB inflater window. Ancillary metadata is skipped without
expansion. Invalid images become negative cache entries, preventing retry loops.

## Reproduction

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-adapter -Doptimize=ReleaseSafe -- --output "$PWD/artifacts/t04/adapter"
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build integration -Doptimize=ReleaseSafe -- --output "$PWD/artifacts/t04/lifecycle"
```

`test-adapter` builds a standalone GIO test driver and runs scripted Unix peers,
then a real nested Aqueous session. `--fake-only` skips the compositor portion.
The driver is not part of Pearl, is not installed by the default build, and its
stdin controls/timing/socket-buffer overrides do not exist in the application.
Private-socket tests need an environment that permits local sockets and nested
compositors; they never mutate the host desktop, configuration or services.

## Current-master command CLI

`pearlctl wm action --text ACTION_JSON` exposes the adapter's typed actions through
Pearl's session-checked control socket. JSON uses the Zig action tag as its sole
key, with a fields object (or `null` for a void action). Requests are capped at
4 KiB and checked against current entity IDs, seat/output availability and
negotiated capabilities both when queued and when dispatched. A successful CLI
reply acknowledges queueing; authoritative state and command completion arrive
asynchronously. Do not assume an accepted request already changed the compositor.

```sh
pearlctl wm action --text '{"window_fullscreen":{"id":"WINDOW_ID","value":true}}'
pearlctl wm action --text '{"window_move_workspace":{"id":"WINDOW_ID","workspace":"WORKSPACE_ID"}}'
pearlctl wm action --text '{"workspace_rename":{"id":"WORKSPACE_ID","name":"Development"}}'
pearlctl wm action --text '{"keyboard_set":{"index":0}}'
pearlctl wm action --text '{"overview_show":{"output":"OUTPUT_ID"}}'
pearlctl wm action --text '{"overview_hide":null}'
```

| Action tags | Fields |
|---|---|
| `window_activate`, `workspace_activate` | `id`, optional `seat` |
| `window_close` | `id` |
| `window_minimized`, `window_maximized`, `window_fullscreen` | `id`, boolean `value` |
| `window_move_workspace` / `window_move_output` | `id`, `workspace` / `output` |
| `workspace_rename` | `id`, `name` |
| `keyboard_set` | `index`, optional `seat` and `group` |
| `keyboard_next` | optional `seat` and `group` |
| `overview_show`, `overview_toggle` | `output` |
| `overview_hide`, `session_reload` | `null` |

`session_reload` uses the settings reload owner and is blocked while a save is
unresolved. Direct `session_exit` is rejected: the existing lifecycle logout flow
owns confirmation. Stale, unknown, locked or unsupported targets fail instead of
being retargeted by label. Native window capture uses a separate foreign-toplevel
identity, documented in [CLIPBOARD_CAPTURE.md](CLIPBOARD_CAPTURE.md); those IDs
must not be substituted for the canonical IPC window IDs above.
