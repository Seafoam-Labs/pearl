# Notification transfer progress plan

Status: phases 1–2 implemented (Pearl hint/rendering + Phyto reporter); the
optional bar-button indicator and trash/delete coverage remain future work.
Scope: Pearl shell and the Phyto file explorer (`subprojects/phyto`). No Aqueous
compositor changes: notifications are a session-bus service Pearl already owns.

## Goal

While Phyto copies or moves files, Pearl's notification surfaces — the toast
surface and the notification center opened from the bar's notification button —
show a live progress card: a progress bar, transferred size, item count, and a
Cancel action. When the batch ends, the same card is replaced by a result
notification (complete / cancelled / partial failure) that stays in history.
Everything degrades gracefully: DND, lock screen, notification filters, Pearl
restarts, and sessions where another daemon (or no daemon) owns notifications.

## Current behavior

- Phyto batches run on a GIO worker thread (`src/operations/engine.zig`).
  `Job.bytes` (atomic) counts transferred bytes, `Job.index` tracks the current
  top-level item, `Job.nodes` bounds the walk. There is no pre-scanned total
  size. Feedback today is a status-bar line at completion
  (`Operations.finish`) and a modal "Working…" dialog with a byte count that
  only appears when the user tries to close the window or presents operations
  (`Operations.present`, 250 ms `tick` timer).
- Pearl's notification model (`src/services/notification_policy.zig`) is a
  fixed-capacity record array with `replaces_id` replacement scoped to the
  sender's unique bus name. Replacement bumps `serial` (views refresh) and
  resets `deadline`/`toast_until`. Records have no progress state.
- Cards (`src/desktop/notifications.zig`) render icon, app header, title, body,
  and up to 8 action buttons (toasts show only the first 2 actions plus
  Dismiss). The bar button shows a record count (`src/desktop/bar.zig`).
- The volume OSD already styles a themed `GtkProgressBar`
  (`resources/style.css`, `.pearl-volume-osd progressbar …`) — the pattern to
  reuse for the notification progress bar.
- Test harness: `tests/integration/test_session_services.py` exposes
  notification records through session state (`src/services/session.zig`
  serializes them), sends Notify through a fixture, and observes
  `ActionInvoked`/`NotificationClosed`. Phyto's native suite
  (`subprojects/phyto/tests/native.py`) already exercises copy/paste on a
  private compositor + D-Bus.

## Design

Channel: standard `org.freedesktop.Notifications.Notify` on the session bus,
updated through `replaces_id`. Progress is carried by one new optional hint,
`x-pearl-progress`, which Pearl renders as a bar. No new socket or IPC
boundary; Phyto keeps working without Pearl (other daemons ignore the hint and
still show the text updates; with no daemon, transfers are unaffected).

Lifecycle of one transfer:

1. `Operations.start` → `Notify(replaces_id=0)`:
   summary "Copying 12 items" / "Moving …", body "Starting…",
   `x-pearl-progress` = 0 or -1 (indeterminate), `resident` = true,
   `expire_timeout` = 0 (persistent while running),
   actions `["cancel", "Cancel", "default", ""]`,
   `desktop-entry` = `org.aqueous.Phyto`, app name "Phyto".
   The empty-caption `default` pair registers card-click activation without a
   visible button (existing `pairAction` semantics).
2. Progress updates ≤ every 500 ms, only when bytes/item/state changed, driven
   from the existing 250 ms `tick`: `Notify(replaces_id=id)` with body
   "45.2 MB · item 3 of 12" and an updated hint. One in-flight call at a time;
   newer snapshots coalesce.
3. Collision pause → body "Waiting for a decision…", progress held; resume
   continues updates. The existing modal collision dialog is unchanged.
4. `Operations.finish` → final `Notify(replaces_id=id)` **without** the hint:
   summary "Copy complete" / "Copy cancelled" / "Some items failed", body with
   aggregate counts and size, normal expire timeout. Clearing the hint restores
   normal toast behavior so the result re-toasts and lands in history.
5. `ActionInvoked` with key `cancel` → `job.cancel.cancel()` (same route as the
   dialog's Cancel). `default` → present the originating window.
   `NotificationClosed` for the progress id → the reporter detaches: updates
   stop, the transfer itself continues (dismiss ≠ cancel).

Example payload:

```
Notify("Phyto", id, "org.aqueous.Phyto",
       "Copying 12 items", "45.2 MB · item 3 of 12",
       ["cancel", "Cancel", "default", ""],
       {"x-pearl-progress": <double 0.25>, "resident": <true>,
        "desktop-entry": <"org.aqueous.Phyto">},
       0)
```

### Hint contract

- `x-pearl-progress`, type `d` (double).
  - `0.0 … 1.0`: determinate fraction.
  - `-1.0`: indeterminate (total unknown).
  - Absent: ordinary notification. A replacement that drops the hint clears
    progress state (this is how the final result is expressed).
  - NaN, infinities, or values outside `[-1, 1]` are ignored (treated as
    absent); an invalid hint never fails the Notify call.
- `GetCapabilities` gains `"x-pearl-progress"` so clients can probe support.
- Sender guidance (documented for third parties): keep `expire_timeout = 0`
  and `resident = true` while running; send the final replacement with a normal
  timeout and no hint; throttle replacements (Pearl re-renders on every
  replacement).

### Progress semantics (what the bar means)

The engine does not pre-scan trees, so totals are not generally known:

- Single regular file: worker pre-pass queries `standard::size` once
  (cancellable) → determinate `bytes / total`.
- Batch of >1 top-level items: fraction = completed top-level pairs / total
  pairs. Documented as item progress; the body always carries the live byte
  count so a batch containing one huge file is still honest.
- Single directory, remote sources where size is unavailable, or any unknown
  total: indeterminate bar (`-1`) plus byte/item text.

No recursive pre-scan: it would double remote-mount traffic and delay start.

### Toast and lifetime policy

- First progress Notify toasts normally (≤8 s). Progress-only replacements
  **preserve** the existing `toast_until` and `deadline`: the toast expires on
  its original schedule instead of being pinned/re-triggered for the whole
  transfer; the card keeps updating in the notification center. The final
  result replacement gets a fresh toast.
- `serial` still bumps on every replacement so views refresh
  (`View.update` early-returns on unchanged serial).
- DND/lock: no toast, center updates continue (existing behavior). Filters
  apply unchanged; a `history_only` decision still updates the center card.
- Replacement reuses the record slot, so the 64-record cap is unaffected.
- Pearl restart / name loss: Phyto's reporter resets its id and re-announces
  on the next tick (new notification, transfer untouched).

## Pearl changes

1. `src/services/notification_policy.zig`
   - `Record.progress: ?f64 = null` (`-1` = indeterminate).
   - `Model.add`: when both the existing record and the replacement carry
     progress, preserve `toast_until`/`deadline`; otherwise keep today's
     semantics. Clearing progress on replacement restores normal toast.
   - Unit tests: progress replacement keeps toast, bumps serial, clears on
     final; invalid values never reach the model.
2. `src/services/notifications.zig`
   - Parse/validate `x-pearl-progress` in the Notify handler via
     `db.lookup(hints, "x-pearl-progress", "d")` (see `dbus_peer.zig`).
   - Add `"x-pearl-progress"` to `GetCapabilities`.
   - `warn()` (shell-local records) unchanged in phase 1.
3. `src/services/session.zig`
   - Include `progress` in the serialized notification records so
     `pearlctl`/integration tests can assert on it.
4. `src/desktop/notifications.zig`
   - `Card` gains a progress row (`GtkProgressBar`) between body and buttons;
     visible iff `record.progress != null`. Determinate → `setFraction`;
     indeterminate → CSS-animated class (respect the GTK animations setting,
     as appearance already does for reduced motion).
   - Same code path serves toast and center. Cancel must be the first action
     pair so it appears in toasts (2-action limit).
5. `resources/style.css` (+ `resources/gtk-theme.css` for the native-GTK path)
   - Trough/progress styling mirroring the volume OSD pattern with palette
     tokens; indeterminate keyframes.
6. Optional, phase 3: bar-button indicator — while any active record carries
   progress, `notification_label` in `src/desktop/bar.zig` shows a spinner or
   percent alongside the count.
7. Any new user-facing Pearl strings go through `dtr("pearl", …)` and the
   existing language-pack tooling.

## Phyto changes

1. New `src/platform/notifications.zig` — `Reporter`, one per `Operations`
   (per window), so concurrent windows each own their notification id:
   - Async session-bus acquisition (`gio.busGet`) and a name watch on
     `org.freedesktop.Notifications`; one connection for all calls (replacement
     is owner-scoped). Reset state on name loss; re-announce on next tick.
   - One-time `GetCapabilities` probe → `supports_progress`; without it, send
     the same replacements minus the hint (text-only fallback).
   - Coalesced sender: at most one in-flight Notify; keep the latest snapshot;
     store the id from the first reply; if the batch finishes before the id
     arrives, chain the final replacement after the reply.
   - `signalSubscribe` for `ActionInvoked`/`NotificationClosed`, matched to the
     connection's unique name and the tracked id; dispatch cancel/default to
     the owning `Operations`; detach on close.
   - All D-Bus work on the main thread; the worker keeps touching only the
     existing atomics. Throttle ≥500 ms with change detection; immediate sends
     on start, conflict pause/resume, and finish.
2. `src/operations.zig`
   - Hooks: `start` → begin; `tick` → update; conflict pause/resume → status
     text; `finish` → complete with `engine.outcome` aggregates.
   - Cancel action → `j.cancel.cancel()`; default → `owner.window.present()`.
   - Existing dialog, status line, undo/redo journal, and close-window guard
     are unchanged — notifications are additive.
3. `src/operations/engine.zig`
   - Optional `total_bytes: ?u64` computed in the worker pre-pass for
     single-regular-file jobs (one cancellable `queryInfo`).
   - Make `index` safe to read from the main-thread tick (atomic or snapshot);
     today it is a plain `usize` written by the worker.
   - Current item display name for the body comes from the owned
     `pairs[index]` (parse name), read on the main thread.
4. Scope: `copy`, `move`, `restore` transfers — paste, drag-and-drop drops,
   and undo/redo of those batches (labels reflect undo/redo). `trash`,
   `delete`, `empty_trash` are a later phase.
5. Strings through `dtr("phyto", …)`; no new dependencies (GIO is already
   linked). Keep aggregate-only logging: notification bodies may show file
   names to the user, but the operation journal keeps its existing
   no-paths payload rule.

## Tests

- Pearl unit (`notification_policy.zig` tests, filter tests unaffected):
  progress replacement semantics, hint validation, serial/toast behavior.
- Pearl integration: new `tests/integration/test_notification_progress.py`
  reusing `test_session_services.py` helpers (`notified`, `records`, `action`,
  `closed`, state records):
  - capabilities include `x-pearl-progress`;
  - a progress Notify sequence updates one record (same id), `progress`
    visible in state, toast flag not re-extended by updates;
  - final replacement clears progress and re-toasts;
  - Cancel action emits `ActionInvoked`; dismiss emits `NotificationClosed`;
  - invalid hint values are ignored, not fatal;
  - capture the notification center showing the bar.
- Phyto native suite (`tests/native.py` extensions, private bus):
  - copy/paste produces the start → throttled updates → final Notify chain
    with correct `replaces_id` and hint;
  - Cancel action stops the job (engine cancellation rules apply);
  - dismissing the notification does not cancel the transfer;
  - with no notification name owned, operations complete unchanged;
  - two windows transferring produce two independent notifications.
- Manual release checks: large copy to USB and SMB, DND on, locked session,
  Pearl restart mid-transfer, collision pause while a progress card is live.

## Phasing

1. Pearl: hint contract, model/rendering, state exposure, unit + integration
   tests. Ships inert (no sender yet).
2. Phyto: reporter, operations hooks, engine totals/index safety, native
   tests. End-to-end feature.
3. Optional: bar-button indicator, trash/delete coverage, documentation and
   translation refresh.

## Risks and decisions

- Toast pinning: deliberately not pinned; initial toast expires, result
  re-toasts. Revisit if users miss long transfers (the center card and,
  later, the bar indicator cover awareness).
- Item-count fraction for nested trees is an approximation; the byte counter
  in the body is the ground truth. Documented in the hint contract.
- Notify flood: bounded by throttle + change detection + single in-flight
  coalescing; a stalled bus never blocks the worker.
- Worker/main-thread `index` race must be fixed before the tick reads it.
- Non-Pearl daemons get text-only updates automatically; the capability probe
  keeps the hint optional. No compositor or protocol changes anywhere.

## Implementation notes

- Indeterminate bars render as a full trough with a CSS opacity pulse
  (`pearl-progress-indeterminate`), silenced by the existing reduced-motion
  class; the body's byte count carries the real progress.
- `Job.index` became a `std.atomic.Value(usize)`; `Job.total_bytes` is an atomic
  sentinel (`maxInt` = unknown) measured once by the worker for single
  regular-file copy/move/restore jobs.
- The reporter coalesces to one in-flight Notify, guards replies with
  connection-epoch and batch counters, and finishes calls against the source
  connection so daemon restarts cannot cross wires. A dismissed card detaches
  updates and suppresses the final result; the transfer itself continues.
- The first Notify is deferred until the GetCapabilities probe answers, so the
  progress hint is present from the first card; periodic ticks are throttled to
  500 ms but post-reply flushes are not, so a fast batch's final replacement is
  never suppressed.
- While a collision pauses the batch, the 250 ms tick skips reporter updates so
  the "Waiting for a decision…" body is not overwritten; the pause update
  bypasses the throttle.
- Phase 1 reports copy/move/restore batches and their undo/redo only
  (`reportable`); other kinds stay inert.
- Tests: `zig build test` (policy + log catalog), `zig build
  test-notification-progress` (Pearl private-bus integration, passing), and
  Phyto's native suite with `tests/notification_sink.py` driving the cancel and
  dismiss routes. The notification checks observe a conflict pause first (which
  guarantees owner discovery) and then a clean copy, so they are deterministic
  even for millisecond transfers. Note: `subprojects/phyto/tests/native.py` has a
  pre-existing failure in its split-pane view-preference block at HEAD (the
  committed `artifacts/native/results.json` is already a failed run); commit
  77f28eea "update split view" changed split panes to fresh tabs inheriting saved
  defaults without updating that block. It is unrelated to this feature and was
  left untouched.
