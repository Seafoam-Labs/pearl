# Aqueous codec and state model (T02)

The pure Zig `codec.zig`, `entities.zig` and `reducer.zig` modules implement IPC
v1 server decoding and schema-1 desktop state. They use Zig 0.16.0 and the standard
library; their tests link neither GTK nor Wayland. Session mode now uses this model.
Persistent transport, outgoing requests, request tracking, acknowledgements,
timeouts and reconnect policy are implemented by the [T04 adapter](AQUEOUS_ADAPTER.md).

## Inputs and compatibility

Implementation was checked against Aqueous revision
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480`, its IPC/shell prose and schemas,
`IpcProtocol.zig`, `ShellManager.zig` and real sanitized IPC fixtures. Exact file
hashes and fixture licenses are recorded in
[the fixture directory](../tests/fixtures/aqueous/README.md).

`entities.zig` defines output, workspace, window, seat, keyboard, keyboard-device
and session records. Required nullable fields must exist. Optional window icon,
tag and description fields default to null; absent optional icon-fetch,
icon-metadata and config-reload capabilities default to false. Unknown fields
are accepted as additive extensions and discarded. Unknown entity kinds,
unsupported IPC/schema versions, duplicate JSON keys, invalid types and invalid
ranges fail explicitly. Numeric entity fields require JSON numeric tokens;
quoted numbers are not coerced.

Entity IDs remain exact opaque strings, keyed by both kind and ID. Removal keys
split at the first colon, so an ID may itself contain colons. Workspace numbers
are display positions, not identity. Sessions require 32 lowercase hex digits.
Sequences, delivery IDs, response IDs and icon revisions remain exact decimal
strings, checked against the compositor's u64 range and a 20-digit local bound.
No value passes through floating-point conversion for identity or continuity.
Geometry uses signed 64-bit values because Aqueous widens outer window geometry
before adding borders. Negative desktop coordinates remain valid.

## Framing and decoding

`codec.Framer.init(allocator, limit)` creates a bounded incremental LF framer.
`push(input)` consumes through at most one LF and returns `{ consumed, frame }`.
The caller retains and subsequently feeds `input[consumed..]`; it can therefore
limit frames processed per GLib callback without accumulating an unbounded
message list. UTF-8 is checked only after the complete frame arrives, allowing
reads to split within a codepoint. Capacity never exceeds the configured frame
limit. An error poisons the stream until `reset`; `finish` rejects partial EOF.
Returned bytes exclude LF and are valid until the next push, reset or deinit.

`codec.decode(allocator, bytes, limits, expected_operation)` owns a fresh arena
and returns `Decoded`. It copies retained strings, so callers may immediately
reuse the input buffer. It validates the frame's UTF-8, byte length and bracket
depth before allocating the JSON tree. Strings and escaped quotes do not affect
depth. The exact raw batch span, including its internal whitespace, is checked
before DOM parsing; escaped `batch` field names work as well. Empty frames,
embedded literal CR/LF, malformed JSON and duplicate keys fail.

Event messages carry a delivery ID and batch. Successful responses require the
operation of the outstanding request, and decode to hello, snapshot, subscribe,
ack, command or window-icon results. Error responses preserve their code and
message. The [T04 adapter](AQUEOUS_ADAPTER.md) validates reply IDs and connection phases.
Icon replies validate metadata, bounds and base64 encoding; PNG decoding and
matching the outstanding size/revision are deferred to the icon consumer.

Hard ceilings, excluding the delimiting LF:

| Budget | Ceiling |
| --- | ---: |
| Outgoing request, enforced by T04 | 65,536 bytes |
| Incoming server frame | 4,259,840 bytes |
| Encoded batch | 4,194,304 bytes |
| Retained entity state accounting | 2,097,152 bytes |
| Complete frame container depth | 16 |

`Hello.effectiveLimits()` can lower these ceilings, never raise them. Tests use
smaller ceilings to exercise exact boundaries. State accounting charges each
key plus 64 bytes and the larger of its typed payload/storage or canonical
known-field JSON. This conservatively extends Aqueous's key + JSON + 64 model;
near the ceiling Pearl may reject a state that fits Aqueous's accounting.
Discarded unknown extensions are not retained. Arena/hash capacity and transient
parser/candidate allocations add overhead: the 2 MiB figure is a logical state
budget, not a process RSS limit. There is no unbounded history or idle work.

## Atomic ownership and derived views

`reducer.Model.init(allocator, state_limit)` starts unavailable. `apply(batch)`
validates continuity, creates a separate candidate arena, clones retained and
replacement entities, then validates the complete candidate graph. Only a fully
valid candidate replaces the live arena. Decode arenas can be destroyed
immediately after `apply`, whether it succeeds or fails. Allocation failures
and invalid batches leave every accepted entity, sequence and borrowed pointer
unchanged.

A snapshot completely replaces state, including on a changed session. A delta
requires an available snapshot, the same session and exact base-sequence string
equality. Its counter must advance, but may jump. Upserts replace full entities;
omitting an optional field clears its former value. Duplicate upserts/removals,
overlapping upsert/removal keys and removals of absent entities are rejected.

The candidate must contain the singleton session record. References must resolve
by kind, connector names must be unique, active workspaces must match their
outputs, window workspace/output associations must agree, and keyboard/seat
associations must agree. The default seat must be unambiguous. Validation runs
after all edits, allowing one delta to migrate workspaces/windows and remove
their former output regardless of array order.

Available queries:

- `get(kind, id)`, `outputByName(connector)` and `activeWorkspace(output_id)`.
- `workspaces(allocator, output_id)`, sorted by number then exact ID.
- `windows(allocator, filter)`, with optional output/workspace and taskbar or
  switcher filtering. Minimized/hidden windows remain represented; the relevant
  skip flag controls inclusion. Results sort by exact ID.
- `focus(optional_seat_id)`, preserving selected output even during layer focus.
  Omitted seat selection fails with `AmbiguousSeat` when several seats exist.

Pointers returned by queries belong to the model and expire after a successful
apply, clear or deinit. The caller owns only the result slices allocated by the
workspace/window list queries and frees them separately. `invalidate()` hides
queries and disallows deltas until a new snapshot; `clear()` also frees the old
state. Already-held pointers must not be presented as current after invalidation.

The T04 adapter invalidates on any broken stream, rejects batches whose session
differs from the verified hello, requires matching sessions across both connections,
and acknowledges an event only after successful validation and installation.
An `apply` error deliberately preserves accepted data for inspection; it does
not itself manage sockets, reconnection or availability policy.

## Verification

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test --summary all
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe --summary all
python3 tests/fixtures/aqueous/generate.py --source /path/to/Aqueous --check
```

The test root is `src/tests.zig`; the Aqueous cases are in
`src/aqueous/tests.zig`. They cover every byte split of four representative
frames, byte-at-a-time Unicode framing, combined frames, malformed/truncated
JSON and UTF-8, size/depth/type/version boundaries, all seven entity kinds,
large counters and geometry, optional-field clearing, duplicate identities,
sequence gaps, snapshot/session replacement, output migration/removal, focus
changes, ambiguous seats and derived lists. Allocation-failure injection checks
every allocation along a decode/snapshot/migration path for cleanup and atomicity.
