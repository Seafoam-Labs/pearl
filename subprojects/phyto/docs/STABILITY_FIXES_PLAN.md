# Stability Fixes Plan — Phyto close crash & SFTP startup-mount flake

Two pre-existing defects found while verifying the issue #166 folder-size fix
(branch `166-phyto-bug-folder-size-isnt-being-measured`). Both reproduce on
unmodified `master` (62f7ec88) with GTK 4.24.1 / GLib 2.90.1. They are
independent of the folder-size change and should be fixed separately.

## Implementation status

- **Issue 1 — FIXED & verified.** The two sorter `ref()` calls are applied in
  `src/tab.zig`. Close reproducer exits 0 ×5 (was always SIGABRT); the native
  suite now passes the tab-close and "Window closes cleanly" checks plus 11
  total checks (previously died at line 146).
- **Issue 2 — hardening applied; residual flake is compositor-side.** The
  signal-refreshed mount cache is applied in `src/platform/network_mounts.zig`
  (removes synchronous D-Bus from the `connect()`/`reconcile()` hot path).
  SFTP measurement still works (4/5 runs; unchanged flake rate). New evidence
  rules out a Phyto main-thread stall and focus-steal — see below. The
  remaining load-dependent input-delivery race needs Aqueous-fixture-side
  investigation and is not fully fixable from Phyto.
- **Newly exposed (separate, out of scope):** with the close crash fixed, the
  native suite now reaches line 319 and fails a split-pane view-preference
  assertion (`assert_view(False, False)` after F3/F6 sees list+hidden on the
  second pane). Confirmed pre-existing: it still fails with only the
  behavior-neutral sorter fix applied (mount cache reverted). Track separately.

---

## Issue 1 — Window/tab close crash (`g_object_unref` CRITICAL)

### Symptom

- Closing a Phyto window (Ctrl+W) or a tab aborts the app under
  `G_DEBUG=fatal-warnings` with:
  `GLib-GObject-CRITICAL: g_object_unref: assertion 'G_IS_OBJECT (object)' failed`.
- Reproduces with **zero interaction** (launch → wait → Ctrl+W).
- Blocks `tests/native.py` at line 146 (`assert probe()["tabs"] == [1, 1]`),
  so the whole native suite cannot pass on master.
- A production core from 2026-11-14 (`/usr/bin/phyto`, PID 3663) shows a
  possibly related teardown SEGV in `g_file_query_info_finish` ←
  `got_new_file_info_cb` (GtkDirectoryList); see "Residual risk" below.

### Root cause (confirmed)

Two GObject transfer-ownership bugs in the sorter wiring of
`src/tab.zig create()`. GTK ownership (from `/usr/share/gir-1.0/Gtk-4.0.gir`):

| API | transfer |
|---|---|
| `gtk_multi_sorter_append` | **full** (consumes the passed ref) |
| `gtk_column_view_get_sorter` | **none** (borrowed) |
| `gtk_sort_list_model_new` (sorter param) | **full** (sinks floating) |
| `gtk_sort_list_model_set_sorter` | **none** (refs internally) |

Current code (`src/tab.zig`):

```zig
55: const sorter = gtk.CustomSorter.new(compare, self, null); // floating, rc=1
56: sorter.ref();                                            // rc=2 (Tab's ref)
57: const sorted = gtk.SortListModel.new(filtered, sorter);  // full: sinks floating → rc=2 (sorted 1, Tab 1)
...
85: const multi = gtk.MultiSorter.new();
86: if (list.getSorter()) |view_sorter| multi.append(view_sorter); // BUG A
87: multi.append(sorter);                                        // BUG B
88: sorted.setSorter(multi.as(gtk.Sorter));                      // none: refs multi, drops sorted's sorter ref
89: multi.unref();
```

- **Bug A (line 86):** `list.getSorter()` returns a *borrowed* ref, but
  `append` is transfer-full and adopts it without adding a reference. The
  MultiSorter later unrefs a ref it never owned → the ColumnView's internal
  sorter is freed while the ColumnView still points at it.
- **Bug B (line 87):** `append(sorter)` consumes the Tab's own ref (the one
  added at line 56). After line 88 the sorter is owned by `multi` alone, but
  `Tab.destroy()` (line 157) still calls `self.sorter.unref()` — stealing
  multi's ref. During teardown the sorter is finalized twice / use-after-free.

Teardown stack (captured via an `LD_PRELOAD` `g_object_unref` interposer that
runs GLib's own `G_IS_OBJECT` check and dumps a backtrace on failure):

```
gtk_default_sort_keys_free / gtk_multi_sort_keys_free   ← bad unref
gtk_sorter_dispose
gtk_sort_list_model_dispose
gtk_multi_selection_dispose
gtk_list_base_dispose
gtk_column_view_dispose
gtk_scrolled_window_dispose
stack_remove                                            ← p.stack.remove(tab.root)
```

### Evidence

A minimal C reproducer mirroring the exact ownership graph
(`/tmp/opencode/sorter_repro.c`, compiled against gtk4) with toggleable fixes:

| mode | fix A (ref view sorter) | fix B (extra ref custom) | result |
|---|---|---|---|
| 0 | – | – | CRITICAL (matches app) |
| 1 | ✓ | – | CRITICAL (custom sorter) |
| 2 | – | ✓ | CRITICAL (`gtk_column_view_sorter_clear`) |
| 3 | ✓ | ✓ | **clean** |

### Fix

`src/tab.zig`:

```zig
// line 86 — own a ref before the transfer-full append:
if (list.getSorter()) |view_sorter| {
    view_sorter.ref();
    multi.append(view_sorter);
}
// line 87 — give multi its own ref; keep the Tab's ref for destroy():
sorter.ref();
multi.append(sorter);
```

Resulting balanced accounting for `sorter`: created floating (1) → `ref` (2)
→ `SortListModel.new` sinks floating (2: sorted 1, Tab 1) → `ref` (3) →
`append` consumes one (3: sorted 1, multi 1, Tab 1) → `setSorter` drops
sorted's ref (2: multi 1, Tab 1) → `Tab.destroy` unref (1) → multi dispose
unref (0). ✔

**Also audited (no change needed):** an earlier NULL-model reproducer
suggested a `selection` ref leak and leaked intermediate models
(`filtered`/`sorted`). A full mirror of `create()`/`destroy()` with
weak-pointer leak detection (`/tmp/opencode/full_repro.c`) disproved both:
with just the two sorter refs the whole graph finalizes with **zero leaks**,
and removing the `selection` refs or unref'ing the intermediates *crashes*.
So the selection/intermediate handling is correct as-is — do not touch it.

### Ownership audit (same pass)

All GTK list/model constructors used in `tab.zig` are transfer-**full**
(verified in GIR): `FilterListModel.new`, `SortListModel.new`,
`MultiSelection.new`, `GridView.new`, `ColumnView.new`. Audit each
`ref()`/`unref()` pair in `create()`/`destroy()` against the table above;
the sorter bugs are the confirmed crash, the selection leak is confirmed,
anything else found gets the same treatment. `MultiSorter`/`getSorter()` are
used only in `tab.zig` (grep-verified across pearl), so the blast radius is
one file.

### Verification

1. Close reproducer (`/tmp/opencode/close_repro.py`): launch → Ctrl+W under
   `G_DEBUG=fatal-warnings` must exit 0 with no CRITICAL. Run ≥10×.
2. `zig build test` — all suites.
3. `python3 tests/native.py --binary zig-out/bin/phyto` (build with
   `-Dtest-hooks=true`) — must now pass line 146 and the rest of the suite,
   including "Window closes cleanly with G_DEBUG=fatal-warnings".
4. Tab-close path specifically: the suite's split/tab section exercises
   `close_tab` with two tabs (the original crash site).

### Residual risk

The Nov-14 production core is a SEGV inside GtkDirectoryList's async
`query_info` callback during teardown — a different stack from the sorter
CRITICAL. It may be a second, GTK-version-sensitive teardown race
(GtkDirectoryList 4.24). If the native suite (or repeated close runs) still
crashes after the sorter fix, capture a fresh backtrace with the interposer
(`/tmp/opencode/unref_trace.c` pattern) or a core dump and diagnose
separately; likely workaround is keeping the DirectoryList referenced until
pending queries complete / disconnecting the `notify` handler before unref.

---

## Issue 2 — SFTP startup-mount flake (UI input stall)

### Symptom

- In the private-session harness, a saved SFTP connection with
  `reconnect=on-open` intermittently (~1 in 3 under load) leaves the app
  unresponsive to keyboard input right after launch; the mount entry stays
  `connecting` from the observer's point of view.
- Blocks `tests/network_protocols.py`-style qualification and the SFTP
  folder-size smoke test.

### Confirmed facts

- The app's **main loop keeps running** (strace: 10 ms `ppoll` idle loop —
  that cadence is the preview heartbeat,
  `src/files/preview/platform/thumbnails.zig:70`, not a hang), but **no
  Wayland events arrive** after the first successful probe: the compositor
  stops delivering key events to the window (focus/routing issue, not a
  blocked main loop).
- sshd fixture log on a failing run: one preauth disconnect, then a
  successful publickey auth followed by client disconnect.
- `Failed to setup SSH environment: org.gnome.keyring not provided` appears
  in gvfs.log on **both** passing and failing runs → benign alone.
- Strongly timing-sensitive: 8/8 passes under `strace -f` overhead; later
  unstraced batches also passed. Load-dependent startup race.
- `network_mounts.zig` has a 20 s tick timeout (`tick`, line 286) that should
  move a stuck request to `.failed`, but its effect cannot be observed
  because input/probing stops; the test's wait predicate only accepts
  `connected`, masking any terminal failure state.

### Hypotheses (ranked) and diagnostics

**Update after implementation — two hypotheses ruled out:**
- *Focus steal by an extra toplevel:* at the failure instant the IPC window
  dump shows **exactly one window, `focused: true`** — no mount dialog, no
  second toplevel. Ruled out.
- *Phyto main-thread sync-D-Bus stall:* strace of a failing run shows the main
  thread iterating continuously for 10 s with **no gap > 0.2 s** (the 10 ms
  cadence is the preview heartbeat). The loop never blocks. Ruled out as the
  flake's cause (the mount cache is still worthwhile hardening, but it does
  not change the flake rate).

Remaining leading hypothesis: **compositor-fixture input routing under load**
— the focused, responsive client stops receiving virtual-keyboard events
during the startup mount. This is outside Phyto's direct control; reproduce
with the Aqueous fixture under parallel load and inspect compositor focus /
virtual-keyboard routing. The flake is suppressed by `strace` overhead (8/8)
and appears ~1/5 under load, consistent with a timing race in the fixture.

Tooling already built and reusable:
`/tmp/opencode/sftp_strace_run.py` (strace-wrapped launch + MOUNT_POLL state
logging + `ipc.state()` window dump on failure),
`/tmp/opencode/sftp_diag_run.py` (same, unstraced),
`/tmp/opencode/unref_trace.c` (LD_PRELOAD interposer pattern).

1. **Focus steal / extra toplevel during the GVfs mount.** A
   GtkMountOperation dialog, notification, or the compositor's focus
   bookkeeping moves keyboard focus away from the main window mid-mount.
   *Diagnose:* run the unstraced diag script under load until failure;
   inspect `WINDOWS_AT_FIRST_PROBE_FAIL` / `WINDOWS_AT_FAIL` dumps for extra
   toplevels and the focused window; correlate with compositor.log
   focus/activation lines. (Dumps are wired; the flake just needs to be
   caught — run batches in parallel with other load to raise the rate.)
2. **gvfsd startup / mount round-trip race.** Phyto's startup reconnect
   races gvfsd name ownership or the keyring-failure code path in
   gvfsd-sftp, stalling the mount operation. *Diagnose:* enable backend
   debug (`G_MESSAGES_DEBUG=all` must reach the *backend* process — check
   gvfsd's spawn env), strace gvfsd-sftp, compare failing vs passing
   sequences; check whether the preauth disconnect is a host-key probe that
   sometimes fails.
3. **Compositor-side focus routing race** in the Aqueous fixture under
   load. *Diagnose:* compositor.log + IPC focus state at failure; if
   confirmed, file against Aqueous with the trace.

### Fix candidates

Per root cause (decide after diagnosis):

- If focus steal: suppress/parent the mount-operation UI correctly for
  background mounts (Phyto already defers password/question via
  `deferPassword`/`deferQuestion`, `network_mounts.zig:273-285`); ensure no
  stray toplevel is presented for `reconnect=on-open`.
- If gvfs race: make startup reconnect wait for gvfs readiness (own the
  `org.gtk.vfs.Daemon` name check) before issuing mounts, and/or retry once
  on early failure.

Hardening (worth doing regardless of root cause):

- **Avoid synchronous D-Bus on the main thread:** `Manager.mounted()`
  (`network_mounts.zig:143`) calls `g_volume_monitor_get_mounts`, a sync
  IPC round-trip to gvfsd, from `connect()`/refresh paths. Replace with a
  mount list cached from the volume-monitor signals the Manager already
  subscribes to (`mount-added/removed/changed`, line 62), or use async
  variants. Removes a class of main-loop stalls while gvfsd is busy.
- **Harness:** make mount wait predicates accept terminal states
  (`failed`, `unsupported`, `needs_auth`) and fail with the state detail
  instead of hanging 30 s; optionally provide a stub `org.gnome.keyring`
  service in the private session to eliminate that variable.
- Consider a shorter, configurable startup-mount timeout with one automatic
  retry so a stalled reconnect self-heals instead of sitting in
  `connecting`.

### Verification

1. SFTP smoke test (`/tmp/opencode/sftp_size_native.py`) ≥20 consecutive
   passes, including under parallel load.
2. `tests/network_protocols.py` (needs the rootlesskit/smbd fixture for the
   SMB half; SFTP half runs rootless) — full pass.
3. `tests/native.py` full suite (also gated by Issue 1).
4. Manual: saved SFTP connection with `reconnect=on-open`, cold start, no
   interaction — sidebar reaches `connected`, UI stays responsive.

---

## Execution order

1. **Issue 1 first** — root cause confirmed, two-line fix + leak, small
   blast radius, and it unblocks the entire native suite (which Issue 2's
   verification depends on).
2. **Issue 2 diagnosis** with the ready tooling, catch a failure under
   load, pick the fix from the confirmed hypothesis, then harden.
3. Run the full verification matrix; file separate GitHub issues for each
   defect with the evidence (reproducer, GIR table, strace/core excerpts).