# sched-ext management implementation plan

Status: implemented, October 9, 2026. The production ReleaseSafe build, 281 model
and wire tests, Settings boundary checks, and the dedicated scheduler integration
suite pass. Broader service/presentation regression failures and the outstanding
real-kernel smoke test are recorded in the
[verification notes](../artifacts/sched-ext/README.md).

Review the [interactive System mockup](mockups/sched-ext/index.html) or its
[screenshots and usage notes](mockups/sched-ext/README.md).

Add scheduler selection and application to Pearl Settings under **System**, using
`scxctl config --json` as the source of scheduler names, configured defaults, and
resolved mode arguments. Enable application only when `scxctl`, the selected
scheduler executable, and a usable loader are detected.

The implementation adds the standalone `system` route titled **System** in
`src/desktop/settings_navigation.zig`. Existing Power & battery and Session & lock
routes remain intact. The sections below retain the implementation requirements.

## User experience

The System page contains a **CPU scheduler** card explaining that sched-ext
controls how CPU time is distributed across applications. Show current scheduler
status separately from the pending selection and the loader's configured default.

Provide a scheduler dropdown, mode dropdown, expandable resolved arguments,
**Apply scheduler**, **Use kernel default**, and **Refresh**. Only show schedulers
with detected executables as selectable options; explain unavailable catalog
entries separately. Changing either dropdown stages a local selection. Applying
uses the selected mode through scxctl, with progress and an inline result.

Use kernel default stops the scheduler managed by scx_loader. Disable that action
when the loader reports none; if the kernel reports an external scheduler, show
that discrepancy instead of claiming the kernel default is active.

These are immediate system-wide runtime actions. They do not enter Pearl's
preference draft or use its global Apply & save button. Explain that boot defaults
remain managed by scx_loader configuration. Persistent default editing, arbitrary
arguments, package installation, and systemd service management are follow-ups.

| Detected condition | Page behavior |
| --- | --- |
| scxctl absent | Explain the optional dependency; disable scheduler controls and offer Refresh. |
| JSON command unsupported | Explain that the installed scxctl or loader lacks the required config interface. |
| No matching scheduler executables | Show the missing scheduler dependency state without an enabled Apply action. |
| Loader unavailable or access denied | Show the specific failure and Refresh; never display cached state as current. |
| Kernel sched-ext interface absent | Explain that sched-ext support is unavailable; disable mutations. |
| Readable catalog and status | Enable applicable controls for installed schedulers. |
| Operation pending | Disable competing mutations while retaining visible selection and progress. |
| Operation failed or outcome uncertain | Refresh observed status, retain the selection, and show a retryable error. |

## Command and data contract

Read-only inspection on this machine found scxctl 1.1.3, scx_loader,
scx_bpfland, and scx_lavd. `scxctl get` reported no running scheduler, and
`/sys/kernel/sched_ext/state` reported `disabled`. These are inspection results,
not assumptions for other installations.

The observed JSON shape is:

```json
{
  "default_sched": null,
  "default_mode": "Auto",
  "scheds": {
    "scx_bpfland": {
      "auto_mode": ["-m", "auto"],
      "gaming_mode": ["-m", "all"],
      "lowlatency_mode": ["-m", "performance", "-w"],
      "powersave_mode": ["-s", "20000", "-m", "powersave", "-I", "100", "-t", "100"],
      "server_mode": ["-s", "20000", "-S"]
    }
  }
}
```

Parse scheduler entries dynamically. Ignore unknown additive fields, validate
required object and array types, and bound document size, entry counts, and
string lengths. Preserve argument arrays for display without interpreting them
as shell commands. A missing mode field is different from a present empty array.

| JSON field | UI label | scxctl mode |
| --- | --- | --- |
| auto_mode | Auto | auto |
| gaming_mode | Gaming | gaming |
| lowlatency_mode | Low latency | lowlatency |
| powersave_mode | Power saver | powersave |
| server_mode | Server | server |

An empty array remains selectable but must say **Uses scheduler defaults**;
for a non-Auto mode, also explain that no distinct mode arguments are configured.
Do not imply that selecting such a mode supplies performance tuning. This matches
the fallback behavior in the [upstream scxctl implementation](https://github.com/sched-ext/scx-loader/blob/main/crates/scxctl/src/main.rs).

Resolve scxctl once per discovery cycle and verify scheduler catalog keys as
executable basenames before checking them in the backend's PATH. Do not run
scheduler binaries to probe availability. A successful loader query demonstrates
loader availability; a separate scx_loader PATH check can inform diagnostics but
must not reject a working daemon installed outside the session PATH. A detected
scheduler binary does not guarantee the daemon can launch it, so launch failures
remain actionable errors.

Use `scxctl get` for runtime status; config JSON alone does not describe what is
running. The installed get command has no JSON flag. Isolate its text parser,
disable color, normalize known scheduler and mode spellings, and cover no-running,
mode, own-defaults, custom-arguments, and unrecognized outputs with fixtures.
Unrecognized output means unknown status, never stopped. Preserve unknown mode
or custom-argument status instead of inventing a selected mode. Read the kernel
sched-ext state as a consistency check and treat disagreements conservatively.

| Intent | Command argv |
| --- | --- |
| Discover catalog | `scxctl config --json` |
| Read runtime state | `scxctl get` |
| Apply with no managed scheduler running | `scxctl start --sched NAME --mode MODE` |
| Apply with a managed scheduler running | `scxctl switch --sched NAME --mode MODE` |
| Return from a managed scheduler to kernel scheduling | `scxctl stop` |

Pass an explicit mode for both start and switch. Do not reconstruct `--args`
from the catalog; the loader already owns resolved mode arguments. The
[upstream command handlers](https://github.com/sched-ext/scx-loader/blob/main/crates/scxctl/src/main.rs)
distinguish start from switch based on whether a scheduler is running.

## Implementation sequence

1. **Model and fixtures.** Add `src/services/sched_ext_model.zig` with pure catalog
   parsing, mode mapping, status parsing, eligibility, and command selection.
   Save representative sanitized config and get outputs under
   `tests/fixtures/scxctl/`. Require support for the JSON capability rather than
   relying solely on a version string. Record the tested client and loader versions.

2. **Shell service.** Add `src/services/sched_ext.zig`, owned by
   `src/ui/surfaces/manager.zig` and wired through `src/core/application.zig`.
   Run subprocess work outside the GTK main thread, using the bounded argv-only
   helper pattern in `src/config/helper_process.zig`. Reuse that helper if its
   existing limits fit, or extract its general mechanism without changing Aqueous
   behavior. Bound stdout, stderr, execution time, and status reconciliation;
   keep one scheduler mutation in flight across all Settings clients.

3. **Settings boundary.** Extend `src/settings/protocol.zig`,
   `src/settings/live_protocol.zig`, `src/settings/live_backend.zig`,
   `src/settings/backend.zig`, and the editor dispatch in `src/settings/editor.zig`.
   Add a typed scheduler snapshot plus refresh and apply/stop requests carrying
   the view, operation ID, and catalog/status generation. Validate ownership,
   route, session availability, generation, scheduler membership, mode, and
   executable availability in the backend. Send identifiers, never arbitrary
   command text or executable paths, from the frontend.

4. **System page.** Add the non-compact route and all exhaustive route handling,
   navigation, title, icon, and fixture updates. Introduce
   `src/settings/sched_ext_view.zig`, hosted by `src/settings/window.zig`, so the
   two dropdowns retain staged values while status refreshes. Existing generic
   live controls dispatch actions individually; use a dedicated view to submit
   scheduler and mode together only on Apply. Match Pearl's English/German copy,
   focus behavior, keyboard navigation, narrow layouts, and status styling.

5. **Verification and documentation.** Add a fake scxctl executable and private
   scheduler executable fixtures, parser/policy tests, and a Settings integration
   suite registered as `test-settings-sched-ext` in `build.zig`. Update
   `docs/SETTINGS_FRONTEND_API.md`, `docs/SETTINGS_SERVICE_OWNERSHIP.md`, and
   `docs/SERVICES.md` with the operation contract, optional dependencies, and
   runtime-only behavior.

## Operation lifecycle

Acquire a service view on System page entry and release it on navigation or
disconnect, following existing Settings ownership rules. Discover config on
entry, explicit Refresh, and recovery; poll lightweight runtime status about
every three seconds only while a view is visible. Coalesce repeated reads and
refresh the catalog before applying if its freshness is uncertain.

Before applying, re-read status and revalidate the selected executable and
catalog generation. If the configuration changed, refresh the UI and require a
fresh Apply against the new arguments. Choose start or switch from observed
state. An external change between read and write is an error to reconcile;
do not automatically stop another scheduler or retry a mutation blindly.

Run scxctl with normal session privileges and let the loader's installed access
policy determine authorization. Report denial without wrapping commands in
sudo or pkexec. Never launch the scheduler executable directly.

After a command exits, reconcile get output and kernel state within a bounded
deadline before reporting the observed outcome. A successful command exit alone
does not prove that a scheduler stayed running. A failed switch may also leave
the previous scheduler stopped; display the observed result rather than assuming
rollback. Preserve warnings, including fallback to scheduler defaults.

Lock and connection loss revoke interactive authority and invalidate stale
callbacks. Release polling and cancel owned subprocess work when appropriate,
but treat cancellation after dispatch as an uncertain system outcome: killing
scxctl cannot undo a request already accepted by the loader. Reconcile on the
next authorized view. Closing Settings must not stop an applied scheduler.

## Acceptance criteria

- Missing scxctl, missing or non-executable scheduler files, unsupported JSON,
  inaccessible loader, missing kernel support, empty catalogs, and malformed or
  oversized output all produce useful unavailable states without blocking GTK.
- Fixtures cover null defaults, unknown additive fields, empty versus missing
  modes, custom arguments, ambiguous get output, and client/loader mismatch.
- Selecting dropdown values produces no mutation. Apply sends exactly one argv
  request with the selected scheduler and explicit mode, using start or switch
  correctly. Stop is available only for a scheduler reported as loader-managed.
- Pending operations disable conflicting controls. Stale requests, double
  clicks, cross-view requests, external switches, loader failure, permission
  denial, timeout, and exit-success-without-running are handled explicitly.
- Refresh preserves valid staged selections and focus. A removed scheduler or
  changed catalog disables stale application. Leaving, reopening, locking, and
  disconnecting release observation without reverting completed changes.
- Automated tests use private command fixtures and synthetic kernel state;
  they cannot start or stop a scheduler on the developer's host. A separate
  manual smoke test on a sched-ext-capable test machine verifies real start,
  mode switch, scheduler switch, failure reporting, and return to kernel default.
- Run the normal build and relevant pure tests, the new integration target,
  `test-settings-boundary`, `test-settings-services`, and affected navigation and
  presentation checks. Inspect wide/narrow layouts and keyboard-only operation.

Delivery is complete when an installed scheduler can be discovered, selected,
applied, observed, and stopped through System, while unsupported installations
retain a usable Settings page with a clear explanation.
