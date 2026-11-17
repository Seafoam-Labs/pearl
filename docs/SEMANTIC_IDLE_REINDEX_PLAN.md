# Semantic idle reindex and folder sync plan

Status: implemented November 16, 2026 (S1–S4); real-hardware acceptance gates
below remain pending. Follow-up to the
[semantic search implementation plan](SEMANTIC_SEARCH_IMPLEMENTATION_PLAN.md);
replaces its open M4 watching item and closes the two freshness gaps recorded
there:

1. **Folder-list changes** to an existing index do not trigger a pass — added
   folders wait for a manual **Index now**.
2. **File edits after a pass** are not noticed — there is no filesystem watch,
   so changed documents wait for a manual **Index now**.

Both are fixed here, with one governing rule: **automatic indexing runs
primarily when the computer is idle or in low use.** Explicit user actions
(**Index now**, enabling setup) stay immediate; everything automatic is
scheduled into quiet windows, in bounded bursts that stop promptly when the
user returns.

Implementation notes (deviations and clarifications): event debouncing is a
2 s "events quiet" gate in the scheduler plus GFileMonitor coalescing, not a
per-event timer. The typing signal comes from the input-activity broker's
events, which flow when a plugin subscribes; without them, low-use windows
rely on the confirmed load heuristic (idle windows are unaffected). Idle
resume and input events cancel automatic bursts immediately; inhibitor/load
changes are caught by the 2 s service tick. The periodic rescan only runs
when an index exists and is measured from shell startup. The automatic first
pass is scheduler-routed (a behavior change from the parent plan's immediate
start), with status explaining the wait. Delivered: `search/schedule.zig`
(pure policy + tests), `search/watch.zig`, maintenance idle notifications in
`platform/wayland/idle.zig` + `services/lifecycle.zig`, scoped/burst-limited
indexer passes, service pending/dirty/folder-diff orchestration, host signal
wiring in the manager (broker, power, power-saver, sleep gate), the Background
indexing dropdown and richer status, `semantic_status` JSON fields, config
migration tests and docs.

## Governing policy

| Trigger | When it runs |
| --- | --- |
| **Index now** (button / `pearlctl semantic index`) | Immediately, as today. Explicit user action bypasses the idle gate. |
| Enable setup (runtime + model download) | Immediately, as today. |
| Automatic first pass after applied enablement | Through the scheduler (behavior change from the current immediate start): a short grace period, then the first quiet window. Status explains the wait. |
| Folder added / file events / periodic safety rescan / invalidated index rebuild | Only in an idle or low-use window, in bursts. |
| Folder removed | Immediately, metadata-only: tombstone that folder's entries and commit. No embedding, no runtime, no window needed — results stop showing removed content promptly. |
| Locked session | Never. The existing suspend-on-lock contract is preserved (see open questions). |

Defaults: automatic background indexing **on**; window class **idle or low
use**; battery rules fixed and disclosed (below); one new Settings control,
no new knobs for thresholds.

## Quiet-window signals

All signals are local; none requires network or new dependencies. Pearl already
ships every source listed here.

| Signal | Source (existing) | Rule |
| --- | --- | --- |
| User idle | `platform/wayland/idle.zig` (ext-idle-notify-v1, already used for lock/screensaver) | A dedicated maintenance notification at **180 s** of no input opens an *idle window*. The compositor honors ext-idle-inhibit, so inhibited video/games block it automatically. |
| Activity resumed | Same watcher's resumed event; `input_activity.Broker` | Closes the window; the running burst is cancelled within ~1 s. |
| Idle inhibitors | `input_activity.Broker.inhibited()` (manager already tracks it) | Any inhibitor → no window of either class. |
| Typing / active input | `input_activity.Broker` state/epoch (plugin input-activity feature) | Recent typing → no *low-use* window (idle windows already require no input). |
| CPU load | `/proc/loadavg` (precedent: `agent/benchmark.zig`), CPU count via `std.Thread.cpuCount` | 1-minute load < **0.5 × CPU count**, confirmed by two samples ≥ 15 s apart, for a *low-use* window. |
| Memory | `agent/memory.zig` `availableMiB()` (already used by the runtime guard) | MemAvailable ≥ model weights + 512 MiB headroom; otherwise defer. |
| Power | `services/power.zig` `on_battery`, `battery_state` | **AC:** both window classes. **Battery:** idle windows only, and only while charging or battery ≥ 50%; low-use bursts never run on battery. |
| Power saver | `gio.PowerProfileMonitor` (bound; `power-saver-enabled`) | Power-saver mode defers all automatic passes. |
| Chat busy / live query | Existing `chat_busy` defer and `query_active` yield in `indexer.zig` | Unchanged; bursts also pause between files/batches. |
| Session state | Lifecycle gate (`sleep_pending`, `preparing`), `Service.locked` | Sleep pending/preparing or locked → no window. Screensaver/dim alone do not block. |
| Compositor without ext-idle-notify | Idle watcher reports unavailable | Degrade to **low-use-only** mode (load + activity + inhibitors), disclosed in status. Multi-seat ambiguity (already tracked by `Idle`) also degrades to low-use. |

Two window classes, one scheduler:

- **Idle window** — user idle ≥ 180 s, no inhibitors, memory OK, power rule OK.
  Burst budget **120 s** of indexing work, then re-evaluate; continue while the
  window holds.
- **Low-use window** — user not idle, but load low (confirmed), no inhibitors,
  no recent typing, **on AC**, memory OK. Burst budget **15 s**, then back off
  and re-evaluate. This is the "computer is in low use" case: quiet background
  progress without waiting for the user to leave.

Global rules: at least **5 minutes** between automatic passes (coalesces event
storms); first automatic window no earlier than **120 s** after shell startup
(login settle); a cancelled burst keeps its committed progress (periodic
commits already exist) and reschedules; **Stop** cancels the current burst and
the scheduler retries on the next window.

## Architecture

### Pending state and folder diff (`search/service.zig`)

- New state: `pending: enum { none, incremental, full }`, a bounded dirty-path
  set (≤ 4,096 paths; overflow promotes to `full`), `last_pass_ns`,
  `defer_reason`, and the scheduler state below.
- `configure()` computes the folder-set diff against the previous config:
  - **Removals** apply immediately: tombstone entries under removed folders
    (`underFolders` logic already exists) and commit metadata-only. The
    in-memory store is refreshed; no runtime is loaded.
  - **Additions** set `pending = .incremental` with the new roots as dirty
    scope. No immediate pass.
  - **Model change / chunker invalidation** sets `pending = .full` (the store
    loader already detects `IndexOutdated`); the rebuild runs in windows.
    **Index now** still forces it immediately.
- The existing automatic first pass (`shouldAutoIndex`) keeps its readiness
  predicate but routes through the scheduler instead of calling `indexNow()`
  directly. Readiness inputs are unchanged; window inputs are added.

### Scheduler (`search/schedule.zig`, new, pure policy)

A pure, testable state machine: inputs = the signal snapshot above plus
pending scope and clock; outputs = `wait(reason) | start(burst_budget) |
backoff`. No GTK, no I/O — the service gathers signals (load sampling at most
every 15 s inside the existing 2 s tick) and feeds snapshots in. Burst expiry,
resume cancellation, backoff and the 5-minute quiet interval live here.

### Idle watcher extension (`platform/wayland/idle.zig`, `services/lifecycle.zig`)

- Add one optional maintenance notification slot and two events
  (`.maintenance_idle`, `.maintenance_resumed`) alongside the existing
  lock/suspend/dim/screen-off slots. Lock/suspend behavior is untouched; the
  maintenance timeout is configured independently of the user's idle policy.
- Lifecycle forwards the events through a callback; the manager wires them to
  `Service`, together with `Broker.inhibited()`, broker activity, and
  `power.on_battery`/`battery_state` (read-only; no power-service changes).
- Unavailable notifier or ambiguous seats → report degraded mode; the
  scheduler falls back to low-use windows.

### File watching (`search/watch.zig`, new)

- One `GFileMonitor` per configured folder root, plus subdirectories
  discovered by indexing walks, capped at **256 monitors**. Monitor creation
  failures (inotify limits, unsupported network mounts) degrade gracefully to
  the periodic rescan; status reports the degraded mode.
- Events (created/changed/deleted/moved/changes-done-hint) are debounced
  **2 s** and accumulated into the dirty-path set; deletes tombstone on the
  next pass. Hidden/excluded directories and the index directory itself are
  never monitored (same rules as the walk; prevents self-triggering).
- Monitor overflow or unmount events promote to a full walk.
- **Safety net:** a periodic idle rescan at most every **6 hours** while
  enabled, even with no events — a stat-only walk is cheap and catches
  anything monitors missed (network shares, overflows, missed events).
  Embedding still only happens for changed files.

### Scoped, burst-limited passes (`search/indexer.zig`)

- `pass` gains a scope: dirty paths/roots only (incremental) or the full walk.
  Unchanged-file skipping, tombstones, atomic commits, chat defer and query
  yield are unchanged.
- A burst budget (deadline) is checked between files and batches; on expiry
  the worker commits and returns a "more pending" result instead of finishing.
  Cancellation checkpoints already exist between files/batches and inside
  cancellable HTTP; resume latency target ≤ 1 s.
- The service swaps in the committed store after each burst, so partial
  progress is searchable immediately.

### Settings, status, CLI

- One new control in the Semantic section: **Background indexing** —
  `Idle or low use (default) / Idle only / Manual only`. Battery and inhibitor
  rules are fixed and documented beside it.
- Index status line gains: `12 changes pending · waiting for idle`,
  `Indexing in background… pauses when you return`, `Paused on battery`,
  `Low-use mode (compositor idle notifications unavailable)`,
  `Last automatic pass 5 minutes ago`.
- `semantic_status` JSON (already consumed by Settings and
  `pearlctl semantic status`) gains: `pending`, `dirty`, `window`
  (waiting/indexing/backoff), `defer_reason`, `last_pass_ns`, `degraded`.
  No new CLI operations.

## Integration contracts (touch points)

| Area | Files | Change |
| --- | --- | --- |
| Idle signals | `src/platform/wayland/idle.zig`, `src/services/lifecycle.zig` | Maintenance notification slot + events; forwarding callback; no lock/suspend changes |
| Wiring | `src/ui/surfaces/manager.zig` | Feed maintenance events, broker inhibited/activity, power state into the service |
| Policy | `src/search/schedule.zig` (new) | Pure window/burst/backoff state machine + tests |
| Service | `src/search/service.zig` | Pending/dirty state, folder diff, scheduler tick, burst orchestration, status fields |
| Watching | `src/search/watch.zig` (new) | GFileMonitor lifecycle, debounce, caps, degraded modes |
| Indexer | `src/search/indexer.zig` | Dirty scope, burst deadline, more-pending result |
| Config | `src/agent/config.zig`, `src/config/preferences.zig` | `semantic.background` enum + validation + migration test (absent → default) |
| Settings | `src/settings/semantic_view.zig` | Background dropdown, richer status lines |
| Docs | `docs/ASSISTANT.md`, parent plan, `README.md`, translations | Behavior, defaults, battery policy |

No agent-protocol changes; no new executables; no new dependencies. Power and
broker services are read-only consumers.

## Milestones

- **S1 — Scheduler + folder sync (closes gap 1).** `schedule.zig` with idle
  windows; maintenance notification + lifecycle forwarding; pending state and
  folder diff (immediate removals, queued additions); burst-limited scoped
  passes; automatic first pass routed through the scheduler; Settings
  dropdown + status; pure policy tests.
- **S2 — Low-use windows.** Load sampling, typing/inhibitor signals, AC/battery
  and power-saver rules, degraded mode; prompt-resume cancellation; login
  grace and quiet interval.
- **S3 — File watching (closes gap 2).** `watch.zig` with caps/debounce/dirty
  set, walk-registered subdirectory monitors, overflow promotion, 6-hour
  idle rescan safety net, self-write exclusion.
- **S4 — Hardening and acceptance.** CLI/status fields, docs/translations,
  inotify-limit and network-mount degradation evidence, real-hardware gates
  below.

## Validation and acceptance

Unit/fixture (default suites, no real models or network):

- Window predicate matrix: idle/low-use × AC/battery × inhibitors × typing ×
  load × memory × locked × sleep-pending × power-saver × degraded mode.
- Folder diff: additions queue, removals tombstone immediately without a
  runtime, model change promotes to full, dirty overflow promotes to full.
- Debounce/coalescing; quiet interval; login grace; burst expiry keeps
  committed progress and reschedules; resume cancels within the checkpoint
  bound; Stop semantics; Manual-only disables every automatic path.
- Watch caps and failure degradation; index-directory exclusion (no
  self-trigger); monitor overflow → full walk.

Real-hardware gates (per [RELEASE.md](RELEASE.md), pending until run):

- Idle notification fires at 180 s and resumes within 1 s of input on Aqueous;
  a running burst stops within 1 s and keeps committed progress.
- No indexing during inhibited video playback or gaming (compositor inhibit
  and broker both verified); no low-use bursts while typing.
- Battery: no low-use bursts; idle bursts only charging or ≥ 50%; measured
  drain within the disclosed bound; power-saver defers.
- Load heuristic does not starve single-core machines (relative threshold) and
  does not run away on many-core idle machines.
- inotify-limited container and network-share folder degrade to rescan with
  honest status; 6-hour rescan catches edits made while monitors were absent.
- Zero network traffic during automatic passes; locked session never indexes;
  multi-window rebuild of a large corpus completes with searchable partial
  progress.

## Risks and open questions

- **Idle source availability.** ext-idle-notify is already used by Pearl's
  lock/screensaver on Aqueous, so availability is established there; other
  compositors degrade to low-use-only mode. Multi-seat ambiguity degrades the
  same way (existing `Idle.ambiguous`).
- **Locked machines are the most idle, but stay excluded** to preserve the
  suspend-on-lock privacy contract shared with the assistant. An explicit
  "index while locked" opt-in is a possible future option; it is deliberately
  out of scope here.
- **Monitor storms** (build trees, sync clients): excluded directories,
  debounce, caps and overflow-to-full keep cost bounded; the quiet interval
  prevents thrash.
- **Large rebuilds span many windows.** Progress is committed and searchable
  per burst; status stays honest; Index now remains the immediate override.
- **Load heuristic false positives/negatives.** Relative threshold plus
  two-sample confirmation; idle windows remain the primary path, low-use is
  best-effort.
- Open: exact battery percentage floor (proposed 50%) and burst budgets
  (120 s / 15 s) are initial values to calibrate at S4; whether the periodic
  rescan interval deserves a hidden advanced setting (proposed: fixed 6 h).

## References

- [Semantic search implementation plan](SEMANTIC_SEARCH_IMPLEMENTATION_PLAN.md)
  (parent; M4 watching replaced by this plan) ·
  [Assistant behavior](ASSISTANT.md#semantic-search) ·
  [Session security / idle policy](SESSION_SECURITY.md).
- Existing infrastructure: `src/platform/wayland/idle.zig`
  (ext-idle-notify-v1), `src/platform/wayland/input_activity.zig` (broker,
  inhibitors), `src/services/lifecycle.zig` (idle events, AC/battery policy),
  `src/services/power.zig` (battery state), `src/agent/memory.zig`
  (MemAvailable), `src/agent/benchmark.zig` (`/proc/loadavg` precedent),
  `gio.FileMonitor` / `gio.PowerProfileMonitor` (bound).
