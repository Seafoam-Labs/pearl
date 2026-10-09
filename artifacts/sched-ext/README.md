# System scheduler verification

The System page and shell-owned scxctl adapter are implemented. The page stages
scheduler/mode selection, displays resolved arguments and current status, and
supports Apply scheduler, Use kernel default, and Refresh. Changes are runtime
only. See the [implementation plan](../../docs/SCHED_EXT_IMPLEMENTATION_PLAN.md).

## Passing checks

- `zig build install build-settings-test -Doptimize=ReleaseSafe` builds production
  binaries and the instrumented Settings executable.
- `zig build test -Doptimize=ReleaseSafe`: 281 model and wire tests pass, including
  catalog/status parsing, mode fallback, state consistency, and optional fields.
- `zig build test-settings-boundary -Doptimize=ReleaseSafe`: transport, connection
  isolation, capabilities, stale requests, and backend recovery pass. The
  [boundary report](regressions/boundary.json) records the checks.
- `zig build test-settings-sched-ext -Doptimize=ReleaseSafe`: all 13 integration
  checks pass. See [report.json](report.json) and [verification.log](verification.log).

The scheduler suite runs the actual shell, frontend, and GTK controls in a
private Aqueous session. A fake scxctl, inert scheduler executables, synthetic
kernel state, and a nonexistent system-bus endpoint prevent access to host
scheduler management. It covers discovery, selection without mutation, native
Apply/Stop/Refresh, start versus switch, empty modes, missing executables/modes,
stale requests, config revalidation, external runtime changes, concurrent
requests, failed switches, unconfirmed attachment, timeout, dependency recovery,
lock, page release, cancellation, and stopped polling after the last view.

GTK on this machine intermittently emits two frame-timing warnings during
popover and window changes: `gdk_frame_timings_discarded()` on an already
presented frame, and the `gdk_frame_timings_throttling_hint` preparing-state
assertion. This suite keeps criticals fatal and permits only those two warning
messages at log review; every other warning remains a failure.

## Native captures

- [Available System page](session/system-ready.png)
- [Running scheduler](session/system-running.png)
- [Missing scxctl](session/system-unavailable.png)
- [480-pixel System window](session/system-narrow.png)

The available and narrow captures were visually inspected. Narrow placement
uses a fresh window, matching the existing presentation suite's handling of
cached GTK minimum-size hints. The page scrolls and retains accessible controls.

## Remaining verification limits

The complete Settings service and presentation regressions are not green.
Initial runs terminated on the GTK frame-timing warnings above. Temporary reruns
allowed only those two warnings without modifying the existing suites:

- [Service regression](regressions/services/report.json) timed out waiting for a
  network credential prompt after restarting Settings; see
  [the failure trace](regressions/services.log).
- [Presentation regression](regressions/presentation/results.json) exercised
  the System route in its page inventory and scaling checks, then lost the
  compositor during output removal. See [the failure trace](regressions/presentation.log)
  and [compositor log](regressions/presentation/session/compositor.log).

These failures remain recorded rather than counted as passes. The default
combined regression log is retained in [initial.log](regressions/initial.log).

Installed scxctl and scx_loader both report 1.1.3; their configuration and status
were inspected read-only. Real BPF attachment, scheduler performance, and loader
permission policies still require a smoke test on a dedicated sched-ext-capable
machine. No host scheduler was started, switched, or stopped for this work.
