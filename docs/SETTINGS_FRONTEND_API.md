# Settings frontend API, version 1

S1–S6 implementation notes, September 15, 2026. The standalone GTK4 frontend
and backend adapters are Zig in `src/settings/`. Handshake, committed appearance,
page snapshots, shared Pearl/Aqueous drafts and live-service adapters are implemented.
Capabilities are enabled only when their backend adapters are attached.
This endpoint is independent of Pearl control v1. S5 routes CLI show commands to the installed frontend.

## Identity, authentication and transport

The backend listens at `$XDG_RUNTIME_DIR/pearl/SESSION/settings.sock`, beside
`control.sock`. `SESSION` is the verified 32-character Aqueous session token;
the Wayland shell protocol identity must match the Aqueous IPC identity before
publication. Loss of verified availability closes all frontend connections.
The backend has a fresh random `epoch` on every endpoint incarnation, including
restart in the same compositor session. Epochs are identity, not credentials.

Reuse `cli.protocol.displayPath` for normalized absolute display paths,
`cli.server.privateDirectory` for owned private directories, and
`aqueous.transport.Transport` for nonblocking framing and same-UID credentials
on both accepted and outgoing sockets. Socket and lock paths must reject symlinks;
only the lock owner removes an owned stale socket. Backend lock:
`settings-backend.lock`; shell lock remains `instance.lock`.
The frontend's S2 instance lock/socket are `settings-app.lock` and
`settings-app.sock` in the same verified session directory, separate from both.
GTK app ID remains `org.aqueous.Pearl.Settings`, with global D-Bus instance
forwarding disabled. Unverified/offline startup does not claim a verified lock.

Same UID is the trust boundary, not a sandbox between applications of one user.
A claimed session token alone is never authentication. Each side verifies peer
credentials; frontend discovery verifies its own display/session first and
compares the returned session/display. Do not discover by enumerating another
session's sockets or fall back to a parent session. Validate the owned directory
and socket before opening. S2 implements this discovery on GTK's own Wayland
connection, binding only native session capabilities and creating no shell roles.

Wire: LF-terminated UTF-8 JSON, no literal LF inside a frame. Reject invalid UTF-8,
duplicate/unknown fields, wrong JSON types and nesting beyond the operation's
limit before dispatch. No shell strings, embedded commands or credential logging.
Unsigned counters cross the boundary as decimal strings, at most 20 digits and
no larger than u64. Request IDs are positive and strictly increasing per
connection. A reconnect starts a new sequence; it never resends a mutation.

First request (exactly these five fields):

```json
{"settings":1,"id":"1","session":"0123456789abcdef0123456789abcdef","display":"/run/user/1000/wayland-1","op":"hello"}
```

`ping` uses the identical shape and checks identity again. Success:
`{settings:1,id,ok:true,result:{session,display,epoch,capabilities,limits}}`.
Failure: `{settings:1,id,ok:false,err:{code}}`; an unparseable request uses
`id:"0"`. Protocol/identity errors close after replying; oversized, invalid UTF-8,
empty or pipelined frames close immediately. Hello is required once. The S1 baseline returned only `handshake:true`; S3 additionally advertises
`committed_appearance`, `page_snapshots` and `pearl_draft`. `Version`, `StaleSession`,
`DisplayMismatch`, `HandshakeRequired`, `AlreadyInitialized`, `StaleRequest`
and `InvalidRequest` are distinct errors. An incompatible peer cannot edit.

The implemented editor capabilities are: `page_snapshots`,
`pearl_draft`, `aqueous_draft`, `live_controls`, `prompts`, `display_preview`.
Each snapshot also reports per-operation availability and a disabled reason;
global capability does not imply device availability or permission while locked.

### S2 read-only appearance and activation

The backend additionally advertises `committed_appearance:true`. Hello and ping
results include `appearance:{revision,mode,variant,gtk_name,font,font_size,density,
reduced_motion,palette}`. `revision` is a decimal string; the other values use
the existing preference and palette types. The backend borrows its current
committed preference service and resolved palette. This appearance snapshot contains committed values only; draft content uses
the separate document operations below. The frontend validates the snapshot before
applying it and invalidates its cached revision on connection loss.

S3 subscribes to change events and refreshes committed appearance after an
event. Its steady-state heartbeat is **15 seconds**, with one request outstanding
and a five-second reply deadline. The one-second S2 compatibility heartbeat is
used only when talking to a backend without the editor capability.
An unavailable or incompatible session leaves a normal window with an explicit
Retry action. The frontend neither starts Pearl nor writes preference files.

Instance routing uses a separate bounded same-UID endpoint with an eight-client
limit, 8 KiB frames, five-second deadline and one activation per connection:

```json
{"settings":1,"session":"0123456789abcdef0123456789abcdef","display":"/run/user/1000/wayland-1","op":"activate","page":"aqueous","section":"displays","activation":"LAUNCHER_TOKEN"}
```

`op` defaults to `activate`, `page` to `overview`; `section` and `activation` are
optional. Sections use the shared route validator. Unknown fields and invalid
targets fail before visible state changes. Success is
`{settings:1,ok:true,result:{accepted:true}}`; failure is
`{settings:1,ok:false,err:{code}}`. Production rejects the instrumented `probe`
operation. Its test-only geometry reply permits 256 KiB; production activation
frames remain limited to 8 KiB. Only the instance lock owner removes a stale socket. Concurrent
secondary launches wait up to five seconds for the owner's socket to appear.

GTK global D-Bus forwarding is disabled while retaining the stable application
ID. A secondary process verifies native and IPC identity before forwarding its
target. Launcher context is consumed from the environment or GDK's retained
startup notification ID, then passed to the existing GTK window before present.
The pinned Aqueous compositor requires valid user activation context to restore
a minimized window; a tokenless command still selects the requested page but
cannot override compositor focus-stealing policy. Private tests exercise a real
GTK/GIO launcher click, concurrent launches and parent/nested isolation on a
shared D-Bus session. Physical desktop activation remains an S6 check.

## Resource budget

The source of wire constants is `settings.protocol.Limits`. S1 accepts only the
8 KiB handshake envelope; the larger frame/document budgets become active with
the corresponding advertised capabilities.

| Resource | Hard limit / behavior |
| --- | --- |
| Connections | 8; excess socket closed before decoding; the app uses two (Pearl/live pages and Aqueous) |
| Handshake | 8 KiB, depth 1, 5 seconds including partial input |
| Enabled editor frame | 256 KiB excluding LF; request depth 4, response depth 12; embedded document validated separately |
| Output queue / concurrent request | One frame / one unanswered request per connection; pipelining closes; no unbounded event backlog |
| Decoder memory | A fixed 8 MiB envelope arena per decoding turn and returns `ResourceLimit` on exhaustion |
| Heartbeat / idle timeout | Frontend pings every 15 seconds; close after 45 seconds without a valid request, including stalled output |
| Pearl document | 65,536 bytes, same as `preferences.max_bytes`; invalid raw JSON may be retained but cannot apply |
| Aqueous candidate | 4 MiB, same as `aqueous_model.max_request` |
| Aqueous schema/snapshot/report | 16 MiB **per document**, same as `aqueous_model.max_response` |
| Document transfer | 32 KiB decoded UTF-8 chunk, at most 512 chunks, one transfer per connection, 30 seconds absolute lifetime |
| Transfer memory | At most 16 MiB per connection (128 MiB for eight), immutable transfer copies; source serialization is bounded separately at 16 MiB |
| List response | At most 16 rows per response, offsets through 128; `next_offset` and source `truncated` explicit; requests require the current page revision |
| Dirty-update coalescing | 150 ms trailing debounce, 1 second maximum latency; retain only latest local draft; flush on navigation/close |
| Subscription backlog | One coalesced state marker and one lock marker per connection; materialize updates when output is free |
| Completion ledger | 64 outstanding/recent operations globally, terminal outcomes retained 10 minutes; never evict pending/unknown entries; return `Busy` when full |
| Prompts | At most the existing single pending operation per service; response <= 1024 UTF-8 bytes, then existing service-specific validation; never put secrets in snapshots |
| Expiry | Network activation 90 s; Bluetooth pairing 90 s, other requests 15 s, discovery 30 s; polkit 120 s; use backend's earlier actual deadline |

Model audit: Network has 8 adapters/devices, 64 APs and 32 saved connections;
Bluetooth has 8 adapters and 64 devices; Audio has 128 entries; notification
history has 64 records with up to 8 actions each. Model label/path limits (for
example 512-byte connectivity paths, 2048-byte notification bodies) still apply.
Each route exposes one paginated row list; use `next_offset` for remaining rows.
Audio target labels are bounded to keep dense choice controls within frame limits. Preserve model `truncated` flags;
do not silently present omitted devices as a complete list.
Pearl's 16 output overrides, 16 pinned apps and 8 export templates fit its existing
document validation. The Aqueous 16 MiB response cannot fit one frame: chunking
is mandatory, not a reason to truncate schema coverage.

A 32 KiB chunk can expand sixfold in JSON escaping and still fit one 256 KiB
frame. Chunk boundaries must preserve UTF-8. Empty raw drafts are supported.
Declared sizes, actual total bytes, contiguous offsets and digest must agree;
reject excess bytes immediately. No partial transfer mutates a backend draft.
Stale revision, expiry, disconnect or digest failure drops staging only.

## Editor message schema (S3–S4)

Every post-handshake editor request has exactly
`{settings,id,session,display,epoch,op,params}`. `params` is an operation-specific
object from the tables below; omitted optionals are absent, not null. All
revisions, generations, offsets, operation and prompt serials use decimal strings.
Replies retain the success/error envelope above; domain failures keep the
connection usable. Events have `{settings:1,event,epoch,revision,data}` and no
request ID. Revisions are scoped to a named domain and do not compare across
domains. Unknown events require resnapshot, never guessed mutations.

| Operation | Exact params / result contract |
| --- | --- |
| `page.enter` | `{page, section?}` using `settings_navigation.Target`; returns `{page,view,revision,available,reason?,snapshot}`. Server binds service leases to this connection; `view` is a connection-local serial, never a backend owner token. One active page. Validate new target before releasing old page. |
| `page.leave` | `{view}`; idempotent cleanup of this connection's view; releases this connection’s discovery/prompts and preview. The app’s preview uses its separate Aqueous connection and survives page navigation. |
| `page.get` | `{view,revision?}`; current immutable snapshot or `{unchanged:true}`. Explicit external navigation resets heading; internal focus/scroll remain frontend-local. |
| `list.get` | `{view,list,revision,offset}`; `{summary,pending,truncated,rows,offset,next_offset,prompt}`; `list` must be `items`. Revision mismatch returns `Stale`; restart pagination. Never mix generations. |
| `document.get` | `{domain,kind,revision}`; `{transfer,revision,bytes,sha256,chunks}` for immutable revision. Domain `pearl` or `aqueous`; Pearl kinds `committed`, `draft`, `base`; Aqueous also supports `review`, `report`, `preview`. The committed Aqueous document contains the complete schema/snapshot and raw files. |
| `document.read` | `{transfer,offset}`; `{offset,text,done}`. Only contiguous reads on the initiating connection; expires after 30 seconds. |
| `document.begin` | `{domain,expected_draft_revision,base_revision,bytes,sha256}`; `{transfer}`. Writable kind is always draft. Pearl base is a preference revision; Aqueous base is its decimal snapshot version; the candidate’s `expected_generation` remains the helper’s generation string. |
| `document.write` | `{transfer,offset,text}`; `{next_offset}`; no partial draft acknowledgment. |
| `document.finish` | `{transfer,operation}`; compare revisions again, atomically retain whole draft, return the terminal operation receipt described below. Only this acknowledgment establishes backend retention. |
| `document.cancel` | `{transfer}`; idempotent disposal of this connection's staging. |
| `draft.discard` / `draft.merge` | `{domain,expected_draft_revision,operation}`; terminal operation receipt, followed by fresh page metadata; Pearl only, using existing three-way merge; Aqueous uses `aqueous.action`. Conflict returns recoverable details, never overwrites automatically. |
| `draft.validate` | `{domain,expected_draft_revision,operation}`; Pearl only; operation receipt and validation result; retains invalid raw draft. |
| `draft.apply` | `{domain,expected_draft_revision,base_revision,operation}`; Pearl only; operation acknowledgment. Separate domains cannot be combined. |
| `operation.get` | `{operation}`; `{operation,state,receipt,error_code}` or `{state:not_found}`, scoped to the authenticated UID/session. `not_found` is not permission to replay an unknown operation. |
| `aqueous.get` | `{}`; snapshot/draft/review/report versions, capabilities, busy/conflict/error states, persistence/receipt/reload results and preview phase/seconds/ownership. Subscribes to changes. |
| `aqueous.action` | `{operation,expected_draft_revision,version,action}`; actions `refresh`, `validate`, `apply`, `discard`, `rebase`, `reload`, `keep`, `revert`. Existing helper/native lease is authoritative. Keep/Revert require the owning connection. |
| `frontend.close` | `{last_draft_revision?}`; verifies prior Pearl acknowledgment, requests owned preview rollback, releases interests/prompts, acknowledges cleanup. The app flushes Aqueous on its separate connection first; `PreviewPending` keeps close waiting until the native job finishes. Unknown rollback stays visible until resolved; lease timeout is authoritative on crash. |

`state.changed` events coalesce domain revision/dirty markers. `lock.changed`
hides the window without re-presenting it on unlock and revokes interactive
views; acquire fresh views only on explicit presentation. Preview phase, seconds and ownership arrive through `aqueous.get` after state
changes and drive fixed window-wide Keep/Revert controls. Page/list snapshots
include a prompt only for its initiating connection, with service, serial, kind,
title and permitted non-secret challenge values. A secret answer is
never echoed in a reply, event, log, probe, saved focus identity or ledger.

### Implemented Pearl editor details (S3)

Appearance, Bar & dock, Session and Advanced share the Pearl draft. All routes
retain its metadata; service pages additionally expose immediate controls. Pearl document kinds are `committed`,
`draft` and `base`. The committed document uses the preference revision; draft
and base reads use the monotonically increasing draft revision. A clean draft
reads as the full committed document. Invalid and empty candidates remain exact
text, so Advanced can repair them.

All mutating operations return `{operation,state,receipt,error_code}`. The receipt
contains decimal-string `draft_revision` and `revision`. `document.finish`
acknowledges whole-document retention only when `state` is `succeeded`; validation,
base revision and dirty/conflict state come from the next `page.get`. Apply may
return `pending`; change events and `operation.get` reconcile its eventual result.
Successful persistence with an export failure remains `succeeded`, with a separate
`export_error` in page metadata. A save failure leaves the draft and live values.

Compare-and-swap protects retention, Discard, Merge and Apply. Allocation failure
cannot replace the previous shared draft. Apply captures the draft serial and
clears only that serial on completion, including when a later serial has identical
text. The legacy CLI `preferences status.draft_revision` remains the committed
base revision; `draft_serial` exposes the new serial. Settings-v1 uses the correct
`draft_revision` name throughout.

The backend holds one bounded transfer per peer, with an absolute GLib expiry timer.
Pearl transfers allow 64 KiB; Aqueous uploads allow 4 MiB and downloads 16 MiB.
It clears staging on disconnect and lock. One pending input frame may wait behind
an outgoing event; a second pending request closes the connection. One coalesced
state marker and one lock marker bound event backlog. Eight peers share a fixed
8-MiB decoding arena per callback, not one permanent arena per connection.

Appearance edits preserve the entire parsed document; Advanced edits its exact
JSON. Draft retention is debounced, with immediate flush on navigation or close.
The footer applies or discards **all Pearl changes**, regardless of the selected
page. Wallpaper selection is a normal transient file chooser. Its cancellable
asynchronous preview has no persistence side effect.

Appearance's **Sync to greeter** button and the retained settings flyout share
`settings/greeter_sync.zig`. It snapshots the current validated draft and runs an
asynchronous native image conversion and polkit-authorized appearance update.
This action does not commit or discard the Pearl draft. The separately packaged
`pearl-greeter-sync` helper owns the system greeter write; it accepts only theme,
background mode/color and PNG bytes. See [greeter appearance sync](GREETER.md#sync-appearance-from-settings)
and `zig build test-greeter-sync-ui` for both frontend paths and cancellation tests.

Backend loss moves the frontend's acknowledged candidate into local recovery
storage without allocating or replaying it. Reconnection downloads the new state;
Apply stays disabled until explicit review/Merge or local Discard. Closing with
untransferred changes offers **Keep open** or **Discard untransferred changes and
close**. Already retained backend drafts remain untouched. Lock suspends transfers
and hides the window; unlock requires explicit presentation before fresh page
interest or editing resumes. Advanced also offers a read-only saved-JSON window
for reviewing overlapping conflicts.

The accepted 64-entry/10-minute operation ledger also bounds editor mutations.
When full, `Busy` preserves the candidate and requires a later retry; pending
receipts are never evicted to make room.

### Live-service operations (S4)

Typed immediate request operation names and params:

| Operation | Params and authority |
| --- | --- |
| `audio.set` | `{view,operation,generation,device,kind,volume?,mute?,make_default?,target?}`; existing `policy.Write`, `Audio.request`, ranges and device identity |
| `brightness.set` | `{view,operation,generation,percent}`; current backlight identity/availability and `Power.setBrightness` |
| `profile.set` | `{view,operation,generation,profile}`; map current stable profile name to index only after generation check; `Power.setProfile` |
| `network.action` | `{view,operation,generation,path,action}`; `scan`, `connect`, `connect_saved`, `disconnect`, `enable`, `disable`, `cancel`; existing Network methods and connection-owned lease |
| `network.editor` | `{view,operation}`; backend authorizes launch; frontend uses fixed `nm-connection-editor.desktop` with a normal GDK launch context; no caller-supplied executable |
| `bluetooth.action` | `{view,operation,generation,path,action}`; `pair`, `connect`, `disconnect`, `trust`, `untrust`, `power_on`, `power_off`, `discover`, `stop_discovery`, `cancel`; existing Bluetooth guards |
| `prompt.answer` | `{view,operation,service,prompt,accept,text?}`; connection ownership, live serial and expiry checked before `Network.answer` / `Bluetooth.answer`; clear decoding and staging secret buffers on completion |
| `notifications.action` | `{view,operation,action,notification?,serial?,key?}`; `dnd_on`, `dnd_off`, `clear_history`, `dismiss`, `invoke`; IDs/actions required only for matching operations, existing notification authority |
| `lifecycle.action` | `{view,operation,action,confirmation?}`; `lock`, `suspend`, `hibernate`, `logout`, `confirm`, `cancel`, `inhibit`, `uninhibit`; confirmation belongs to initiating connection and current generation |
| `power.action` | `{view,operation,reboot,confirmation?}`; preserve shutdown/reboot inhibitor/auth path and confirmation, `Power.powerAction` |
| `media.action` | `{view,operation,action,generation,position?}`; existing selection, playback and seek via session media controller (wire microseconds, UI seconds); optional Overview link retains current controls |
| `layout.get` / `layout.set` | `{view,operation,output,generation,layout?}`; current enabled output and existing structured compositor transaction |


`operation` is a client-generated 32-lowercase-hex nonce, reserved before any
side effect. Repeated operation with identical caller/params returns its known
state; conflicting reuse returns `Conflict`. Domain adapters serialize through
existing service pending queues and preference/Aqueous job guards. They must not
acknowledge success merely because a request was queued. Before dispatch, reserve
bounded receipt capacity. Never log operation payloads containing credentials.
A reconnect can reconcile a retained operation by its nonce; the backend ledger
stores caller UID/session and epoch. Across backend epochs only Aqueous durable
receipts prove completion; all other unknown outcomes require fresh state and
explicit user intent. Never automatically replay.

## Inventory and extraction map

| Page | Snapshots / complete controls | Existing authority / extraction |
| --- | --- | --- |
| Overview | Per-category summaries, lock/logout/suspend/hibernate, inhibitors, shutdown/reboot confirmations; links to all pages, media and workspace layout | `desktop/panels.zig`, `desktop/lifecycle.zig`, `services/lifecycle.zig`, `services/power.zig`, `services/session.zig`; extract lifecycle confirmation ownership from popup presentation |
| Network | Enabled/hardware radio, connectivity, devices/APs/saved lists, load/truncation/pending/error, prompts and editor launch | `services/network.zig`; reuse F3 leases. Extract serialization and editor launch from `desktop/connectivity.zig` / `Manager.control` |
| Bluetooth | Adapters, paired/unpaired devices, connected/trusted/blocked flags, discovery/pending/error, all prompt kinds including display-only challenge | `services/bluetooth.zig`; reuse F3 prompt ownership, discovery expiry and delayed-start cleanup |
| Sound | Inputs, outputs, streams, defaults, volume/mute, stream targets, availability/generation | `services/audio.zig` / `services/policy.zig`; move `Manager.serviceStatus` serialization to backend adapter; no extra PulseAudio connection |
| Power | Battery/AC/percentage/state/time, profiles, brightness, session link, generation/error/pending | `services/power.zig`; page-owned polling lease, keep shell policy and authorization |
| Appearance | `theme.mode/variant/source/gtk_name/seed`, all wallpaper modes/path/color, font/font_size/density/reduced_motion; committed palette | `config/service.zig` owns draft/validation/save, `desktop/settings.zig` contains form extraction; file chooser/preview in frontend, backend owns actual decoding/commit validation |
| Bar & dock | Bar groups/edge/size/islands; dock enabled/edge/visibility/size/margin; popup dismissal/placement/max size | Same Pearl draft; use full existing `Preferences` / dock schema validation; output overrides remain Advanced |
| Notifications | DND, history entry/list, dismiss/actions/clear history | `services/notifications.zig`, `notification_policy.zig`, `session.zig`; no invented per-app policy |
| Session & lock | Complete `idle` AC/battery lock/suspend policies and capability status | Same Pearl draft; `services/idle_policy.zig` / lifecycle apply on confirmed commit |
| Aqueous | Existing seven sections: appearance/layouts/input/keybinds/rules/displays/advanced; full schema, structured collections, raw files, outputs, native preview, shortcut recording, validation, rebase/reload and durable reports | `config/aqueous_client.zig`, `aqueous_model`, `aqueous_contract`, `aqueous_collections`, `aqueous_display_mutations`, `aqueous_transactions`, `aqueous_operations`; retain schema-driven coverage and helper bounds |
| Advanced | Entire Pearl JSON, output overrides, pins, export templates, invalid text, base/current revision, merge conflicts, validation/save/export failures | `Service.keepDraft/discardDraft/mergeDraft/apply/status`; one draft shared with Appearance/Bar/Session; no second persistence writer |

### Adapter implementation

- `settings/backend.zig` and `live_backend.zig` borrow the shell’s existing services.
  They hold no GTK window pointers. `SurfaceManager` fans out service, lifecycle,
  layout, preference and Aqueous changes to both hosts. The legacy CLI retains its
  strict fields and 8192-byte limit.
- Pearl retention is atomic and fallible, with a draft revision independent of
  committed revision. Apply clears only the submitted serial. Invalid Advanced
  text remains repairable; dependent forms disable until it is valid.
- `aqueous_client.keepDraftExpected` compares both shared draft revision and
  snapshot version before retention. Validation, persistence, native preview and
  durable receipt reconciliation remain in the original backend client.
- `settings/aqueous_editor.zig` is a frontend proxy with a separate authenticated
  connection. Large documents use chunks; navigation flushes local edits without
  ending the window’s display lease. Close waits for rollback; disconnect/lock
  requests rollback and native lease expiry covers crashes.
- Shared `aqueous_settings.ViewFor` and its collection/display editors work with
  either host. Shortcut recording uses the normal application toplevel, stops on
  departure/lock and writes a validated chord through the ordinary draft path.
- Network/Bluetooth/Power leases bind to the authenticated peer; owner tokens
  never cross the boundary. Same-page activation preserves the lease. Foreign
  prompt answers and preview decisions are rejected.
- Polkit registration stays in the trusted shell agent. Correlated service
  prompts use normal transient dialogs; unrelated polkit challenges are never
  broadcast. Password entries and transport/decoding buffers are cleared.
- Aqueous reconnect retains the local candidate without replay. Explicit Rebase
  uses the existing three-way merge against a fresh snapshot, and refuses to
  overwrite a concurrent shared draft. Review drafts provides a read-only copy;
  Discard in recovery drops only that local copy and reloads backend state.

### Draft and disconnect state machine

Frontend edits → bounded local candidate → coalesced transfer → acknowledged
backend draft → explicit Apply → existing validation/persistence → committed
revision event. Navigation/close flush the candidate and wait for acknowledgment.
Close failure offers Keep open or Discard untransferred changes and close;
acknowledged drafts remain in backend memory through frontend exit/crash.
Backend exit loses Pearl drafts; reconnect retains a local candidate, fetches
fresh base/current state, then requires existing merge/rebase. Apply is never
implicit in navigation, close, reconnection or theme refresh.

Leaving a page clears its callbacks/secrets and releases only its service leases.
Leaving Aqueous retains preview controls at window scope. Disconnect cancels owned
unfinished discovery/auth/confirmation, requests owned preview rollback, and
retains established connections. Lock revokes all interactive views, hides the
frontend, clears prompts and rejects mutation; unlock does not present the app.
Output removal invalidates selected output IDs without clearing unrelated drafts.

## S1 evidence and remaining gates

`zig build test-settings-boundary -Doptimize=ReleaseSafe` runs real Pearl
processes and an independent Python protocol peer on two private Aqueous displays.
It verifies handshake, persistent heartbeat, wrong-session/display/version denial,
capability gating, request IDs, fragmented/malformed/oversized frames, timeout,
connection exhaustion, disconnect cleanup and backend restart identity.
Pure tests exercise strict handshake parsing, bounds and shared route/section IDs.
See `artifacts/settings-app/s1/REVIEW.md` for actual results.

S2 window/activation evidence is under `artifacts/settings-app/s2/`. S3 adds
`zig build test-settings-appearance -Doptimize=ReleaseSafe`, using independent
protocol peers and actual GTK input, alongside the existing preferences, window
and boundary regression suites. See `artifacts/settings-app/s3/REVIEW.md`.
S4 adds `test-settings-services` and `test-settings-devices`: real GTK input,
private NetworkManager/BlueZ/PulseAudio/power/session fixtures, complete Aqueous
schema, ownership, recording, native preview and reconnect coverage. See
`artifacts/settings-app/s4/REVIEW.md` for results. S5 packages the frontend and connects desktop, CLI and compact-flyout launch paths.

## Installed launch integration (S5)

The normal build and staging installer include `pearl-settings`, the desktop entry,
matching hicolor icon and AppStream metadata. `pearlctl settings show` defaults to
Overview and accepts shared `--page` / Aqueous-only `--section`; `aqueous show`
accepts `--section` or the legacy `--text` spelling. Validation happens before any
visible state changes. Control-v1 additionally accepts a bounded optional
`activation` token on these two operations only; pearlctl forwards available
launcher context. `--output` remains accepted and validated, with normal window
placement controlled by the compositor.

The verified shell launches its fixed sibling `pearl-settings` with `posix_spawn`
and a GDK activation context, without invoking pearlctl or a command shell. A `-git` shell
selects `pearl-settings-git`; that binary uses `org.aqueous.Pearl.Git.Settings` to
match the co-installed desktop/icon identity. No caller supplies an executable.
`{launched:true}` means the executable started, not that configuration was
saved. Missing binaries return `SettingsNotInstalled`; dispatch errors return
`SettingsLaunchFailed`. Successful launch releases any popup keyboard grab;
failure leaves the popup available. Frontend identity checks and per-session
activation still control whether the new process can open or forward a window.

## Acceptance (S6)

`test-settings-acceptance` runs pure tests and eighteen private-session suites.
`test-settings-presentation` uses live private service fixtures for all eleven
routes, the five reference pages, light/dark/native GTK, narrow and short windows,
100/125/150/200% scale and retained drafts through output disable/move recovery.
The normal-window `test-master-ui` checks production AT-SPI heading roles, active
navigation state and hidden-page exclusion, plus the existing structured editor,
shortcut and receipt assertions through actual keyboard input.

Frontend crash tests cover owned credentials/discovery and native preview
rollback; lock during a frontend-owned preview is also exercised. Physical
activation/unplug and Orca review remain separate from fixture evidence. See
[S6 results](../artifacts/settings-app/s6/REVIEW.md).
