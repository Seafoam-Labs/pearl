# Live plugin discovery validation

Implemented September 18, 2026. See the
[implementation plan](PLUGIN_LIVE_RELOAD_IMPLEMENTATION_PLAN.md) and
[user/developer reference](PLUGINS.md#live-installation-and-updates).

## Delivered behavior

Main Settings has **Refresh plugins**, progress, source/candidate paths and
watch/polling status. `pearlctl plugins refresh` returns a discovery ticket;
`plugins list` exposes its completion and errors. These controls do not apply
settings drafts and do not appear in the flyout.

Installations, updates and removals reconcile immutable package records in the
background. Unchanged instances remain running. Replaced/removed instances stop
and release their transport, timers, activity requests and views. Helper waits
and views retain their own references, so a late exit cannot affect a replacement.
Changed assets invalidate rendering even if scene JSON is unchanged.

Approval covers the current fingerprint. Updates require permission review;
obsolete approvals fail Apply. Missing/invalid packages preserve configuration.
User packages override system IDs; duplicate IDs in one root conflict. Invalid
known overrides remain unavailable rather than exposing a system copy. Complete
root-scan failures preserve the previous index.

The implementation treats a selected **path change** as replacement even when
its bytes match. Only that helper restarts; the existing fingerprint approval
remains valid. This makes subsequent helper starts use the current package path
while views continue owning immutable records.

## Evidence

Tests use temporary installation roots, private displays/buses and mock system
services. They do not modify the user's installed plugins or running desktop.
The reference build uses Zig 0.16.0, Wasmtime 48.0.2 and ReleaseSafe optimization.
Machine-readable results are in [plugin-live-reload-results.json](plugin-live-reload-results.json).

- **130 unit tests** passed, including identity/diff and root/path priority checks.
- **17 helper checks** passed, covering real C/Zig/Rust components, invalid content,
  traps, limits, symlinks and stale generations.
- **100 update/removal/reinstall cycles** passed with one Pearl PID. An unrelated
  plugin kept its helper generation. Helpers stayed at 2, watches at 7, and
  admitted package data at 1,851,394 bytes. Shell file descriptors fell from 32
  to 28; they did not accumulate. Initial automatic discovery took 0.90 seconds.
- A final discovery run passed unchanged refresh, failed-instance isolation,
  event storms/coalescing, traversal exhaustion, stale approval, retained drafts,
  invalid replacements, differing-version conflicts, override precedence,
  unreadable roots, root renames, inactivity and nested PNG-only updates.
- With monitors deliberately disabled, a new package appeared through the
  automatic 30-second fallback. Manual Refresh also worked, with zero watches.
- The runtime-disabled build completed live package operations with **zero
  helpers**, preserving approvals and reporting runtime unavailability.
- The older Aqueous fixture without input-activity support passed the same
  discovery workflow. With working watches, an idle three-second observation
  committed no new scan; total shell CPU averaged about 0.33% of one CPU. This
  includes native UI and a running timer plugin, not just discovery overhead.
- Both normal and deliberately stalled compositor-acknowledgment activity suites
  passed **15 checks**. They replaced/restored the cat during authentication,
  verified hidden views and no replay, resumed activity with the authorized broker,
  and exercised overlapping native lock/PAM. Diagnostic GTK after-paint latency
  maxima were 91.8 ms and 79.8 ms respectively; these are not hardware latency.
- **8 main Settings checks** passed, including the real Refresh button, keyboard
  focus and retained edits across another package update, enable/disable Apply,
  failure isolation, and flyout rejection. Collapsible settings now use a toggle
  and revealer to avoid GTK expander focus traversal into unrooted children.
- The native security suite passed lock, PAM, polkit, idle/suspend, inactive-session,
  independent-locker and recovery checks.

## Reproduce

Build examples with fixtures first, as described in `PLUGINS.md`. Then:

```sh
zig build test
zig build test-plugin-host -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
zig build test-plugins -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
zig build test-plugin-discovery -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
zig build test-plugin-activity -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
zig build test-security -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
```

The discovery target defaults to 100 cycles. Use `-- --cycles 2` for a shorter
iteration, `-- --no-monitors --cycles 1` for fallback coverage, or build with
`-Dwasm-plugins=false` in a separate install prefix for runtime-disabled coverage.
Pass the staged disabled shell explicitly with `--pearl PREFIX/test/pearl-integration`.
Activity tests require the diagnostic Aqueous prefix described in the existing
[activity validation record](PLUGIN_INPUT_ACTIVITY_VALIDATION.md).

## Scope and limits

There is one scan plus one coalesced pending request. Starts are limited to one
per second; event debounce is 250 ms with a two-second maximum deferral. New
watches cause one verification pass. Transient failures get three retries.
Incomplete/degraded monitoring polls every 30 seconds.

Admission remains bounded to 32 packages, 8 enabled configurations and 64 MiB per
index. Current/candidate/retired admitted data share a 128 MiB cap; bounded
read/verification scratch, allocator overhead and helper RSS are separate. Walks
visit at most 2,048 entries and 512 directories; monitors cap at 520. Resource
limits are reported as scan failures, not package removals. CLI pages shrink to
fit their response limit, with bounded candidate/issue details.

This is private-session acceptance, not whole-release or hardware certification.
Physical keyboard/VT, extended multi-output/scale/rotation soak, adversarial
filesystem timing on slow/network filesystems, and exhaustive allocation-failure
injection remain broader release-validation work. The existing activity acceptance
record continues to track hardware and authorization gates. Live plugin discovery
does not reload Pearl's executable or renew revoked compositor launch authority.
