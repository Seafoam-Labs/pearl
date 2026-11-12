# M5: Production terminal and tasks

**M5 is implemented and validated (targeted).** The production terminal uses
**libghostty-vt 1.0.1 — not VTE** — from a private prefix build, with a
**Coral-owned GTK4 Cairo/Pango renderer** driven entirely by ghostty render
state. `src/terminal/pty.zig` spawns and owns the process group; a worker Job is
the **only waitpid reaper**; the GTK main thread reads the PTY master through a
**GIO read watch**. Sessions require **workspace trust plus an explicit
disclosure**, are bounded to **eight per window**, and support
new/close/restart/cancel, resize, scrollback, selection and paste under a **safe
OSC policy** (clipboard denied, title/checksum reports off, Kitty graphics/glyph
disabled, notifications/window-resize ignored). The Terminal dock is the **fourth
dock panel** beside Explorer/Search/Source Control with persisted layout.
Workspace **tasks** load bounded `.coral/tasks.json` definitions (absolute argv,
no shell), require trust plus a **per-run review**, run under the supervised
capture boundary with cancellation/reaping, and classify output with
**zig/gcc/clang/python/generic problem matchers** into an Output/Problems UI with
a navigation callback.

Targeted validation passed: **task-unit 16, terminal native 9, tasks native 9,
docks 27, session-unit 27, widgets 213, hooks-disabled production 46/46 and
visual 16/16**. Final safety review fixes landed and re-passed **terminal native
9/9, surface integration 8/8 and production 46/46**. The **full aggregate was
not rerun per user request**; M1–M4 aggregates remain historical evidence. Explicit limits remain: no rectangular
block selection, fixed Monospace 11pt (not the app font), full-frame rendering
without dirty-row incremental updates, Kitty graphics disabled, tasks without the
manager file barrier, and task navigation that opens files in production but
records intent in the instrumented test binary. **M6 agent core is next.** This
is not full Zed/VS Code terminal parity.

## Renderer decision and private build

The [M0 terminal feasibility gate](WORKBENCH_M0_TERMINAL.md) proved that an
embedded GTK4 VTE widget could render PTY output in the private harness. That
spike remains **historical feasibility evidence, not the production renderer**.
M5 instead adopts **libghostty-vt 1.0.1** as a VT-state engine and keeps drawing,
input translation and process lifecycle Coral-owned:

- `src/terminal/ghostty.zig` binds the libghostty-vt C ABI directly. Signatures
  are checked against `ghostty/vt.h` **1.0.1**. There is **no C bridge and no
  VTE** in the production path.
- libghostty-vt holds VT state only (grid, styles, colors, cursor, selection,
  scrollback, encoders). It does not draw widgets or own processes.
- The optional VTE spike fixtures (`zig build terminal-spike`) remain test-only;
  there is no VTE dependency or install edge in production.

**Private prefix build.** libghostty-vt 1.0.1 was built privately from the
upstream `libghostty-vt-1.0.1` tarball and its dependency tarball under
`pearl/.cache/libghostty/`, producing the prefix
**`pearl/.cache/libghostty/prefix`** (`include/` and `lib/`, including
`libghostty-vt.so.1.0.1` and a static archive). Nothing was installed on the
host; no host package transaction was used. This development host uses Shelly;
repository PKGBUILDs do not identify the host distribution.

**Build option and runtime rpath.** Pass **`-Dghostty-prefix=PREFIX`** where
`PREFIX` contains `include/` and `lib/`:

```sh
cd subprojects/coral
zig build -Doptimize=safe -Dghostty-prefix=../../.cache/libghostty/prefix
zig build run -Dghostty-prefix=../../.cache/libghostty/prefix -- /path/to/project
```

The build adds `PREFIX/include`, adds `PREFIX/lib` as a library path, links
`ghostty-vt` **without pkg-config**, and adds a **runtime rpath to `PREFIX/lib`**
so the executable finds the private library without host installation. The
option applies to the production executable, the headless test module and the
instrumented integration binary. **The M5 terminal requires libghostty-vt**;
supply the prefix for builds and tests that link the terminal.

## Architecture and process ownership

| File | Responsibility |
| --- | --- |
| `src/terminal/ghostty.zig` | Direct libghostty-vt 1.0.1 C ABI bindings; no C bridge, no VTE |
| `src/terminal/surface.zig` | GtkDrawingArea + Cairo/Pango renderer from ghostty render state; key/mouse/paste/selection input through ghostty encoders; safe OSC/effect policy |
| `src/terminal/terminal_controller.zig` | Bounded sessions/tabs, trust + disclosure gate, the **only waitpid reaper** (via the worker Job), GIO read watch, status labels |
| `src/terminal/pty.zig` | PTY spawn/read/write/resize/cancel/wait; authorization; complete environment allowlist; process-group ownership through `ownership.zig` |
| `src/terminal/ownership.zig` | Private non-execing subreaper supervisor; PID pinning; TERM → 150 ms grace → KILL; reaping |
| `src/tasks/task.zig` | Bounded `.coral/tasks.json` parsing and argv/cwd/env policy (pure std, no GTK, no execution) |
| `src/tasks/matcher.zig` | Bounded problem matchers (pure std, no I/O, no execution) |
| `src/tasks/process.zig` | Supervised bounded command capture with owned process-group lifecycle (not a PTY) |
| `src/tasks/tasks_controller.zig` | Task picker, trust + per-run review, run/stop/restart, Output/Problems UI, navigation callback |

**Thread boundary.** A worker thread starts the PTY and is the **sole waiter**;
Coral owns only `waitpid` for its jobs (through the private supervisor). The GTK
main thread never waits on a child: it reads the master fd through a **GIO watch**
(`G_IO_IN | G_IO_HUP | G_IO_ERR`) and feeds bytes to
`ghostty_terminal_vt_write`. Cancellation/reaping never blocks the UI thread; a
bounded finalization destroys sessions once the worker publishes completion.
Linux PTY `EIO` after slave closure is treated as EOF. Outbound PTY writes go
through a **bounded 64 KiB nonblocking ring** drained by a **POLLOUT (`G_IO_OUT`)
watch** only while blocked (overflow is dropped), so the main thread never
busy-retries a write.

**Process-group ownership is not containment.** Each start adds one small
private supervisor process. The command gets its own session; the supervisor
observes the leader with `WNOWAIT` so the unreaped PID pins the process-group ID
through the last group signal. Cancellation, timeout, output limit, owner
shutdown and leader exit apply **TERM → 150 ms grace → KILL**, then reap ordinary
descendants (including non-interactive shell background children). There is no
application-wide subreaper, `SIGCHLD` handler or `waitpid(-1)`. A descendant that
deliberately escapes with `setsid`/`setpgid` is **not contained**, signaled or
awaited; orphan reaping belongs to init. This is **not an OS sandbox**.

## Trust, disclosure and session lifecycle

- A new session requires a current **workspace trust permit** (the `.tasks`
  capability, shared with tasks) **and an explicit per-window disclosure
  acceptance**. Restricted workspaces refuse with `Restricted`; there is no
  terminal execution at startup or in restricted mode.
- The first request shows the disclosure: commands run with your user
  permissions; workspace trust is **not an OS sandbox** and does not approve
  individual commands; terminal output cannot control the workbench (titles,
  links and escape sequences never trigger actions); clipboard access from
  programs is denied by default. Rejecting records an error and spawns nothing.
- **Restart, disclosure acceptance and spawn re-validate trust.** Acceptance
  re-issues the permit because trust may have been revoked since the disclosure
  was requested; a stale permit never spawns. A workspace change cancels/reaps
  every session and resets the disclosure; trust revocation invalidates permits.
- Sessions are bounded to **eight per window** (`SessionLimit` beyond that).
  Defaults are **80×24**. The shell is `$SHELL` when it is an absolute path,
  otherwise `/bin/sh`; the cwd is the first workspace root. The environment is a
  fixed allowlist — `PATH`, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `USER`,
  `LOGNAME`, `SHELL`, `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`,
  `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `TZ` —
  not the full inherited environment.
- **New / Close / Restart / Cancel:** New gates then spawns; Close cancels and
  reaps a running session before destroying it (already-exited sessions are
  destroyed immediately); Restart rechecks trust, cancels the old session and
  spawns a fresh one; **Cancel stops the running command and reaps/removes the
  session**. Exit code or signal is shown in the status line
  (`Terminal N · state · exit/signal · COLSxROWS`). Tab titles follow the OSC
  title as **labels only**.

## Rendering, input, resize, scrollback, selection and paste

- The surface is a **GtkDrawingArea drawn with Cairo/Pango** from ghostty render
  state (rows, cells, styles, colors, cursor, selection). Rendering is
  **full-frame**; there is no dirty-row incremental path yet.
- The terminal font is fixed **Monospace 11pt** (with bold/italic variants), not
  the application font. Cell metrics are measured from Pango; allocation changes
  resize the grid and mirror it onto the PTY (`TIOCSWINSZ`).
- Keyboard and mouse input are translated through ghostty key/mouse encoders
  (Alt sends an ESC prefix). Terminal focus is excluded from palette/global
  shortcut interception; terminal input and composition are not globally
  intercepted.
- **Scrollback** is bounded to **10 MiB / 10,000 lines**; discrete vertical
  scrolling moves the viewport, with scroll-to-bottom.
- **Selection** is mouse-drag (viewport cell coordinates) plus select-all;
  **Copy** writes the selection to the system clipboard as plain text through
  the ghostty formatter. **There is no rectangular/block selection.**
- **Paste** goes through the ghostty paste path: **bracketed paste per mode
  2004** and unsafe-paste rejection; clipboard text is read through GDK.
- There is no hyperlink activation. Title/pwd/bell metadata may update labels or
  notify the controller; they are never connected to action dispatch.

## Safe OSC / effect policy

Terminal output has **no action authority**. The surface configures libghostty-vt
so programs cannot drive the workbench or the clipboard:

| Effect | Policy |
| --- | --- |
| Clipboard read / write (OSC 52) | **Denied by default** |
| Title report | **Off** |
| XT checksum report | **Off** |
| Kitty graphics storage | **0 bytes**; file and shared-memory mediums **off** |
| Kitty glyph protocol | **Disabled** |
| Desktop notifications | **Ignored** (NULL callback) |
| Window-resize requests | **Ignored** (NULL callback) |
| Progress reports | **Ignored** (NULL callback) |
| Title / pwd semantic metadata | Labels only; never dispatch actions |

The native `osc-clipboard-denied` and `no-stdout-injection` cases exercise this
boundary: stdout cannot inject UI commands.

## Terminal dock — fourth panel, persisted layout

The Terminal dock is a real **fourth dock panel** beside Explorer, Search and
Source Control, with an activity-rail button and same-dock tabs. It moves
**left/right/bottom**, resizes, hides and focuses like the other panels.
`layout.State` persists the terminal dock side and visibility through sessions;
the default is a **hidden bottom panel**, and old sessions without terminal
fields decode to that default. Compact windows keep the shared one-auxiliary-
panel presentation. Session roundtrip/partial/refusal tests and the native docks
suite cover the terminal layout alongside the existing panels.

## Commands

All M5 commands are palette/menu-driven; **none has a default keybinding**.

| Action | Palette label |
| --- | --- |
| `toggle-terminal` | Toggle Terminal dock |
| `focus-terminal` | Focus Terminal |
| `terminal-new` | Terminal: New session |
| `terminal-close` | Terminal: Close session |
| `terminal-restart` | Terminal: Restart session |
| `terminal-cancel` | Terminal: Cancel running command |
| `tasks-show` | Tasks: Run task… |
| `tasks-run` | Tasks: Run selected task |
| `tasks-stop` | Tasks: Stop task |
| `tasks-restart` | Tasks: Restart task |

## Tasks: definitions and policy

Definitions come from **`.coral/tasks.json` in each available workspace root**,
loaded off the GTK thread and aggregated under a **total 64-task limit**.
Executable workspace content is **not trusted by default**.

```json
{
  "version": 1,
  "tasks": [
    {
      "name": "zig build",
      "argv": ["/usr/bin/zig", "build"],
      "cwd": ".",
      "env": {"PATH": "/usr/bin:/bin", "HOME": "/home/user"},
      "matcher": "zig"
    }
  ]
}
```

Policy enforced by `task.zig` (parsing performs no execution):

- **`argv[0]` must be an absolute path.** Elements are literal: **no shell, no
  PATH lookup, no expansion**.
- **`cwd` is root-relative** and resolved lexically inside the owning workspace
  root. Symlink escape by a reviewed cwd/argv is not contained; the review shows
  the resolved path.
- **`env` is a complete allowlist** — nothing is inherited, not even `PATH` or
  `HOME`. It may be empty.
- `matcher` is optional (`zig`, `gcc`, `clang`, `python`, `generic`); omitting it
  disables problem matching for that task.
- Only known fields are accepted; duplicate fields and duplicate task names are
  refused; version must be **1**. A SHA-256 digest of the source bytes detects
  definition changes between loads.

Bounds: **64 tasks total, 64 KiB per file, JSON depth 8, 64 argv elements, 64 env
entries, 128-byte names, 8,192-byte strings, 4,095-byte paths**. UTF-8 and
structural depth are checked before DOM allocation; control characters are
refused.

**Trust plus per-run review.** A run requires the workspace trust permit
(`.tasks`) **and an explicit per-run review of the exact argv, working directory,
environment allowlist and matcher** before anything executes. Neither gate is an
OS sandbox: a reviewed command runs with the user's permissions and can read/write
files and access the network. **Tasks do not take the manager file barrier** —
they are not assumed to mutate workspace files — but the trust boundary still
applies.

## Tasks: supervised capture and problem matchers

Runs use the `tasks/process.zig` supervised capture boundary (**not a PTY**):

- Combined stdout/stderr capture is bounded to **1 MiB**, with a **30-second
  timeout**. Outcomes are `success`, `nonzero`, `signaled`, `spawn_failed`,
  `cancelled`, `timed_out`, `output_limit` and `io_failed`.
- **Stop cancels and reaps the process group** (TERM → 150 ms grace → KILL);
  Restart re-reviews the exact command after the previous run completes.
  Generation/workspace tokens discard stale results without skipping cleanup.
- The environment passed to the child is the complete reviewed allowlist.

`matcher.zig` classifies only text the supervisor already captured; it never
opens, runs or mutates anything:

- **zig / gcc / clang / generic** match `file:line:col` diagnostics; **python**
  matches tracebacks. Severities are error/warning/note/info.
- Bounds: **1,000 problems, 4,095-byte paths, 2,048-byte messages**; lines longer
  than **8,192 bytes** are not scanned. Excess matches set a visible `truncated`
  flag rather than silently dropping problems. Control characters in file paths
  are refused because paths are navigation targets.

## Tasks: Output/Problems UI and navigation

The task surface is a native picker dialog (up to 64 tasks, shown as
`name — argv[0]`) with Reload and Run/Stop/Restart controls, a captured
**Output** view labelled with the run outcome, and a **Problems** list showing
severity, file, line and message (at most **256 visible** of the 1,000 matched).

Activating a problem delegates to a **parent-supplied navigation callback**. The
controller resolves relative problem paths against the task's working directory
before calling, passing 1-based line/column (column 0 when unknown). **In
production the callback opens the file** (`openExisting`; the current handler
opens the file without line positioning). **In the instrumented test binary it
records the navigation intent** (path/line/column) instead of opening, because
opening a document there would race harness teardown; the native
`navigate-problem` case asserts the recorded intent. This is a test-harness
boundary, not a production limitation.

## Limits and intentional differences

- **No rectangular/block selection**; selection is drag/select-all plain text.
- **Fixed Monospace 11pt**, not the application font; no terminal font preference.
- **Full-frame renderer**; no dirty-row incremental rendering yet.
- **Kitty graphics and the glyph protocol are disabled**; no image display.
- No hyperlink activation; title/pwd are labels only; no shell integration
  beyond semantic metadata.
- **Eight sessions per window**; no cross-window terminal transfer.
- **Tasks take no manager file barrier** (trust boundary); they are bounded
  reviewed commands, not a general build system, and have no task dependencies,
  parallel task runs or problem-matchers beyond the five kinds.
- **Task navigation opens files in production; the test binary records intent.**
- Process-group ownership is **not containment**: deliberate `setsid`/`setpgid`
  escapees are not signaled or awaited; reviewed commands run with user
  permissions. **Not a sandbox.**
- The visual gate is existing-workbench regression coverage, **not
  terminal-window visual parity**.

## Targeted validation

**Targeted validation passed; the full aggregate was not rerun per user
request.** M1–M4 parent aggregates, production and visual gates remain
historical evidence and are not relabelled as M5 validation.

| Target | Result | Evidence |
| --- | --- | --- |
| `task-unit` | **16/16** (definitions + matchers) | `src/tasks/task_test.zig` |
| `terminal` (native) | **9/9** | [standalone results](../.cache/m5-terminal-native/results.json), [final results](../.cache/m5-final-native/results.json) |
| `tasks` (native) | **9/9** | [final results](../.cache/m5-tasks-final/results.json), [earlier results](../.cache/m5-tasks-native/results.json) |
| `docks` (native) | **27/27** (184.620 s) | [results](../../../.cache/coral-docks/results.json) |
| `session-unit` | **27/27** (incl. terminal layout roundtrip) | [units log](../../../.cache/coral-m5-units.log) |
| `widgets` | **213/213** (48.284 s) | [units log](../../../.cache/coral-m5-units.log), [results](../../../.cache/coral-widgets/results.json) |
| Hooks-disabled production | **46/46 steps** (fresh 43 s compile) | [production log](../../../.cache/coral-m5-production-final.log) |
| `visual` | **16/16 cases, 40/40 steps** | [visual log](../../../.cache/coral-m5-visual.log), [results](../../../.cache/coral-visual/results.json) |

Native terminal cases: `trust-gate`, `output-render`, `resize`, `exit-restart`,
`cancel-reap`, `close-sessions`, `session-limit`, `osc-clipboard-denied`,
`no-stdout-injection`. Native tasks cases: `trust-refusal`, `disclosure-reject`,
`load-and-select`, `run-review-reject`, `run-and-match`, `navigate-problem`,
`stop-and-reap`, `restart-reruns`, `bounded-problems`. The 16 visual cases are
eight theme/width cases plus eight font-ratio checks (native/follow at 1.0 and
2.0). Counts overlap across harnesses; they are not a unique-test total.

`zig build test-m5-slice` composes **only the changed M5 surfaces** (`task-unit`,
`terminal`, `tasks`); it does not include M1–M4 regressions.

**Retained earlier failures (not current successes):** the combined
[final-native attempt](../../../.cache/coral-m5-final-native.log) recorded tasks
**8/9** (`navigate-problem` private-session condition timed out) alongside
terminal 9/9 before the passing standalone tasks rerun; an
[earlier docks attempt](../../../.cache/coral-m5-docks.log) failed and was
superseded by the final 27/27 run. These attempts are retained as history; the
passing results above are the accepted targeted evidence.

### Final safety review fixes — re-passed

The final safety review landed four fixes, and the affected surfaces re-passed
within the same targeted framing (the full aggregate was not rerun):

- **Terminal Job atomic cancel-before-publish gate.** A `cancelled` atomic flag
  ordered seq_cst against the phase publish means a cancel racing with spawn is
  never lost: the worker re-cancels after publishing the handle, and `cancel()`
  cancels immediately when the handle is already visible (idempotent). Joining
  only after cancel completes within the ownership grace — **no missed cancel
  and no UI join hang**.
- **Surface paste GCancellable lifetime.** The async clipboard paste context is
  heap-owned by the `GCancellable` (`g_object_set_data_full`) with an extra
  cancellable ref during the callback, so it outlives the Surface; `deinit` sets
  the cancelled flag before freeing, and `pasteReady` never dereferences freed
  storage — **no use-after-free**.
- **Nonblocking bounded PTY outbound queue.** Input/effects enqueue into a
  64 KiB ring drained by a POLLOUT watch; overflow is dropped — **no main-thread
  busy retry**.
- **Disclosure/spawn trust re-validation.** Disclosure acceptance and spawn
  re-issue the `.tasks` permit, so a permit revoked after the disclosure was
  requested refuses the spawn.

**Re-pass evidence:** terminal native **9/9**
([safety-fix results](../.cache/m5-terminal-fix/results.json), 20.267 s), surface
integration **8/8** (the GTK-backed surface tests in `src/terminal/surface.zig`:
VT rendering/resize/paste/OSC denial and a real PTY round-trip under the
worker/GIO model), and hooks-disabled production **46/46 steps** (fresh 43 s
compile, [production log](../../../.cache/coral-m5-production-final2.log)).
These re-passes supersede the earlier terminal/production runs above for the
fixed surfaces; the other targeted counts remain as recorded.

Commands (from `subprojects/coral`, with the private prefix):

```sh
zig build task-unit -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build terminal -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build tasks -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build test-m5-slice -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build session-unit -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build docks -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build widgets -Doptimize=safe -Dghostty-prefix=../../.cache/libghostty/prefix -- --aqueous-prefix /usr
zig build -Doptimize=safe -Dtest-hooks=false -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
zig build visual -Doptimize=safe -j1 -Dghostty-prefix=../../.cache/libghostty/prefix
```

## Next

**M6 agent core is next.** M7 terminal threads will reuse this PTY service with
the same execution disclosure. Remaining M5 polish (incremental rendering, app
font integration, block selection, richer shell integration) is documented
future work, not a delivered or promised capability. See the
[implementation plan](WORKBENCH_IMPLEMENTATION_PLAN.md) and
[current status](WORKBENCH_STATUS.md).
