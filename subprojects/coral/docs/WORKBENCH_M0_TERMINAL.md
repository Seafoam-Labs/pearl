# M0 terminal feasibility: GTK4 VTE

**Decision (2026-11-08): close the M0 terminal-renderer feasibility subgate.**
An actual GTK4 VTE widget, embedded by Zig beside another GTK widget, has rendered
PTY output and accepted real Wayland keyboard input in the existing private
Aqueous harness. Select **optional GTK4 VTE + Coral-owned PTY/process lifecycle**
as the feasible integration strategy. This is not transport-only evidence, an
external terminal window, a mock emulator, production application wiring, or M5
acceptance. Other M0 gates are unaffected.

No `app.zig`, `main.zig`, root build files, existing transport files, live
configuration, or package database were changed by this work. All new application
implementation and fixture-peer logic is Zig; Python only orchestrates tests.

## Candidate comparison and native availability

Searches covered `subprojects/dome/src`, `src`, `build.zig*`,
`bindings/README.md`, and Coral's workbench plan and terminal sources. Search terms
included `vte`, `vte_terminal`, `vterm_`, `libghostty`, `terminal`, and `ghostty`.

| Candidate | What actually exists | Decision |
| --- | --- | --- |
| GTK4 VTE | Maintained terminal emulator **GtkWidget**, public C ABI, foreign-PTY API, rendering/input/selection/scrollback/VT parsing | Demonstrated here; preferred optional dependency |
| Pearl's Ghostty-named dependency | `ghostty-org/zig-gobject` generated GTK/GDK/GIO/GLib/Pango bindings; **not** the Ghostty terminal engine or an embeddable terminal | Reuse binding conventions/types, not an imagined renderer |
| Pearl terminal integration | `src/agent/runtime_install.zig` launches foot/Ghostty/kitty/etc. as separate processes; theme code exports terminal colors | External launch/configuration, not a widget |
| Dome | GTK application infrastructure; no matching terminal implementation in its `src` search | No reusable Dome terminal found |
| Coral `pty.zig` | Tested Linux PTY byte transport, authorization, process ownership/reaping | Reuse ownership, not as an emulator |
| Host libvterm | `pkg-config vterm` reports **0.3.3**; parser/state library rather than GTK renderer | Would require drawing, shaping, IME, selection, accessibility and scrolling integration; unnecessary for this gate |

Native probes:

- Zig **0.17.0**, GTK **4.24.1**, GLib **2.90.1**, Pango **1.58.2**,
  glibc **2.44**, Linux x86_64 **7.3.3-1.1-devario-llm**.
- Initially `pkg-config --modversion vte-2.91-gtk4` **failed**. GTK4 was present.
- Ran `shelly --help` and `shelly search --help` before dependency work.
  `shelly search standard vte4 --detail` reported available, **not installed**,
  `vte4 0.84.1-1`, GTK4 widget, LGPL-3.0-or-later. No `pacman`, `makepkg`,
  privileged installation, or host dependency transaction was used.
- Built upstream **VTE 0.84.1** with GTK4 enabled, GTK3/application/GIR/Vala/docs/
  Glade/systemd integration disabled, in `pearl/.cache/coral-terminal-spike/`.
  `pkg-config` with the private prefix reports **0.84.1**.
- Missing system simdutf/fmt/fast_float were satisfied by the release archive's
  bundled subprojects (**8.2.0 / 12.1.0 / 8.1.0**), using Meson's
  `--wrap-mode=nodownload`. The earlier `nofallback` attempt correctly failed.
- Host `glib2-devel` tools `glib-mkenums` and `glib-genmarshal` were absent.
  Used upstream GLib **2.84.3** scripts privately, substituting only their shebang
  and version placeholders. A private copy of `glib-2.0.pc` overrides only the
  marshal tool path, not the installed library/includes/version. No native
  library or VTE source patch was necessary.

### License qualification

The VTE widget sources (`src/vte.cc`, `src/vtegtk.cc`) carry LGPL-3.0-or-later
notices; the upstream demonstration application (`src/app/app.cc`) is GPL-3.0-or-
later and was **not built or copied**. `COPYING.README` explicitly requires
per-file license inspection and lists the accompanying license texts. Dynamically
linking the widget is a viable integration route, not a claim that every VTE
source file has the same license. Release packaging must retain applicable
notices/source availability and satisfy LGPL replacement/relinking obligations,
including review of bundled dependencies if shipping a private build. Do not copy
upstream demo-app code into Coral. Final distribution/license review remains a
release task; this fixture makes no project-wide license change.

## Implemented boundary

- `src/terminal/spike_abi.zig`: small, opaque public GTK4/GIO/GLib/VTE C ABI;
  no C implementation shim and no new generated binding dependency.
- `src/terminal/spike.zig`: retained VTE widget and stable-address ownership job.
  A GLib worker invokes `pty.start` and the single blocking `wait`; acquire/release
  state publication separates it from GTK operations on the main thread.
- `src/terminal/spike_fixture.zig`: independent native executable. A label and
  terminal share a `GtkBox`. It registers a real ancestor `workbench.tripwire`
  GAction to detect unwanted action activation and handles compositor close.
- `src/terminal/spike_child.zig`: deterministic Zig PTY peer. Checks all three
  standard descriptors are terminals, emits fragmented UTF-8 and hostile VT/OSC,
  verifies the input bytes, reads `TIOCGWINSZ`, and creates a TERM/HUP-ignoring
  same-group descendant for cleanup tests. No shell or workspace code runs.
- `src/terminal/spike_test.zig`: worker denial/exec-failure regression tests.
- `tests/terminal_spike.py`: real-display acceptance using existing
  `scripts/pearl_session.py::PrivateSession`, Aqueous IPC, `wtype`, `wl-paste`,
  `grim`, and screenshot sanity checks. It never installs/builds dependencies.

### PTY and lifetime contract

1. Authorize exact argv/cwd/environment; start the existing PTY on a worker.
   Job configuration strings must live until start has published readiness;
   the Job itself must retain a stable address until `finish`.
2. Duplicate the master with `F_DUPFD_CLOEXEC` and pass it to
   `vte_pty_new_foreign_sync`. VtePty consumes this descriptor, including failed
   initialization finalization. `vte_terminal_set_pty` retains the VtePty.
3. **VTE is the sole reader/writer and resize owner** after attachment. Do not
   simultaneously drain `Pty.read`, write through the original handle, or change
   its shared file-status flags. Allocation changes propagate through VTE to the
   actual PTY; no invented text-grid renderer or polling copy bridge is involved.
4. **Do not call `vte_terminal_watch_child` or VTE spawn APIs.** Coral's private
   supervisor owns child reaping. VTE must not become a second waiter.
5. On cancellation or close, close the ownership control channel; keep the
   widget/state alive while the worker finishes. The fixture hides the closing
   window, keeps processing GTK, observes VTE EOF and worker completion, detaches
   the PTY, joins the completed worker and destroys the widget. Normal exit
   leaves terminal contents available for inspection before final close.

The fixture pumps the default context with bounded iterations for deterministic
control; a production GtkApplication should use ordinary async completion and
application holds, not copy its polling main loop or stdin command channel.

### Output is data, not authority

There is no path from terminal text/metadata to the command registry, action
activation, URL opener, filesystem/config writer, or harness control parser.
Only VTE parses PTY output. Hyperlinks and sixel are explicitly disabled;
scrollback is bounded to 1,000 lines; audible bell is disabled. No title, cwd,
OSC 133/777, shell integration, resize-request, or link signal is connected to a
workbench callback. The window title is supplied by the host, not terminal OSC.

The test's control channel is **inherited stdin of the host fixture**, separate
from the slave PTY given to the peer; it is not part of the candidate's production
API. Its few commands are literal test controls, not terminal output dispatch.
The peer receives a minimal explicit environment, no bus/display/socket/config
credentials. Logs JSON-escape extracted terminal text instead of printing raw
control sequences.

VTE 0.84.1's tested OSC 52 behavior leaves the clipboard unchanged; this adapter
does not add a clipboard handler. Keep that regression test when upgrading VTE.
This is an architectural authority boundary plus adversarial sequence evidence,
**not** proof against every possible native-library parser vulnerability or a
sandbox against the running process.

## Executed native evidence

Two consecutive complete private-display runs passed on 2026-11-08:

- `pearl/.cache/coral-terminal-spike/evidence/run-1jgw6g40/results.json` — **4.377 s**.
- `pearl/.cache/coral-terminal-spike/evidence/run-y3yskfy0/results.json` — **4.490 s**.
- `evidence/results.json` is the latest-run pointer; per-run JSON/logs/screenshots
  are preserved. These generated local artifacts are not tracked source files.

Actual harness compositor provenance: revision
`e32ab7fc8f6510b393780b811ef92fe1bac6438e` from the prepared fixture selected by
`fixture_prefix()`, not an assumed installed `/usr` compositor or the unrelated
production-prefix metadata. Results include its full baseline, private socket,
fixture binary hashes, `/proc`-observed loaded library paths/hashes, PID evidence,
text/grid snapshots, and screenshots. PrivateSession verifies its fixture hashes,
uses private HOME/XDG config/cache/state/runtime, display and buses, and cleans up
the session. VTE's private loader path is supplied to the fixture only, after
starting the compositor; no host environment import or profile sourcing.

| Check | Native result |
| --- | --- |
| Actual embedding | VTE widget mapped inside the host GTK window with a sibling label; not a spawned terminal app |
| Unicode output | Byte-by-byte `héλ 中文 é 🙂` decoded by VTE; exact extracted UTF-8 asserted |
| Visible rendering | `grim` PNGs captured; first exit capture visually inspected: Latin/Greek/CJK, combining accent, color emoji and green ANSI text visibly rendered |
| Unicode input | Private Wayland `wtype` delivered `héλ中文🙂` + Return; child byte-checked it and printed the matching `INPUT:` reply |
| Resize | VTE allocation **25 rows × 88 columns → 27 × 115**; child's `RESIZED:27 115` matches VTE's reported grid |
| Hostile output | JSON action text, OSC 0/2 title, OSC 7 cwd, OSC 8 `coral://workbench.tripwire`, OSC 52 write, OSC 777, OSC 133 and CSI window-resize request; action count stayed **0**, title/grid unchanged, private clipboard sentinel unchanged |
| Positive authority control | Explicit host-side activation **from the terminal widget** finds the ancestor GAction and increments count to **1**; output never increments it |
| Normal exit | Status **1792** (exit 7), spawn errno 0, `reaped=1`, VTE EOF, final `EXIT:7` text retained |
| Cancellation | TERM-resistant leader/group escalated to SIGKILL, raw status **9**, `reaped=1`, EOF and clean widget teardown |
| Actual window close | Aqueous `window.close` → GTK close-request → async cleanup; status **9**, `reaped=1`, executable exits 0 |
| Reaping checks | `/proc` confirms disappearance of leader, stubborn same-group descendant **and private supervisor** in every case |
| Fresh launch | Second normal-exit case after cancel/close passes; this is a new process/widget, not in-place session restoration |

Screenshot reviewed:
[embedded terminal](../../../.cache/coral-terminal-spike/evidence/run-1jgw6g40/0-exit.png).
PNG variance is only an automated nonblank sanity check, not OCR or full glyph
coverage. Unicode input here is a virtual-keyboard test, **not physical IME
preedit/composition qualification**.

Loaded VTE shared library SHA-256:
`11a369e3d19aed73a2b6efa508057e188549ca2c166d8a28897a7ed835266124`.
Loaded GTK library SHA-256:
`1f33e5bdb0eda46d1b58f638e73fac1549350d6160d69d46fd90eeb9c29deda0`.

Additional validation:

- `zig test src/terminal/pty.zig -lc -O safe`: **4 passed**.
- `zig test src/terminal/spike_test.zig -lc -lglib-2.0 -O safe`:
  **6 passed** (two worker checks plus four imported transport tests).
- `zig fmt --check src/terminal/spike*.zig`, Python syntax compilation and
  `git diff --check` passed. The unrelated whole-application suite was not run.

Initial failed fixture runs remain in the evidence directory: setting a clipboard
before obtaining a Wayland input serial was rejected, and immediate independent
`wtype` Return delivery was unreliable. The runner now establishes a modifier-only
input event before setting the sentinel and uses the existing harness's 40 ms
key-event startup delay. No renderer bypass or direct PTY input was substituted.

## Reproduce without root-build edits

With the private VTE prefix already built, run from `pearl/subprojects/coral`:

```sh
zig build-exe src/terminal/spike_child.zig -lc -O safe \
  -femit-bin=../../.cache/coral-terminal-spike/spike-child
zig build-exe src/terminal/spike_fixture.zig -lc -O safe \
  -lgtk-4 -lgobject-2.0 -lgio-2.0 -lglib-2.0 \
  -L../../.cache/coral-terminal-spike/prefix/lib -lvte-2.91-gtk4 \
  -femit-bin=../../.cache/coral-terminal-spike/spike-fixture
zig test src/terminal/spike_test.zig -lc -lglib-2.0 -O safe
python3 tests/terminal_spike.py \
  --binary ../../.cache/coral-terminal-spike/spike-fixture \
  --child ../../.cache/coral-terminal-spike/spike-child \
  --vte-prefix ../../.cache/coral-terminal-spike/prefix
```

These are standalone compiler commands, **not new `zig build` targets**. The
link names are those tested here; future build wiring should resolve them through
`pkg-config gtk4 vte-2.91-gtk4`. With a supported system VTE, omit the private `-L`
and runner `--vte-prefix`. Missing VTE or display is a failure, not a passing skip.
`--aqueous-prefix` can explicitly select another prepared existing harness fixture.

### Private dependency build provenance / recipe

Working directory: `pearl/.cache/coral-terminal-spike` (create it first). Network
access is only needed for these public upstream sources; nothing from the project
or terminal output is uploaded. No paid service/API key is needed.

```sh
curl --fail --location --max-time 45 -o vte-0.84.1.tar.xz \
  https://download.gnome.org/sources/vte/0.84/vte-0.84.1.tar.xz
sha256sum vte-0.84.1.tar.xz
tar -xf vte-0.84.1.tar.xz
curl --fail --location --max-time 30 -o glib-mkenums.in \
  https://raw.githubusercontent.com/GNOME/glib/2.84.3/gobject/glib-mkenums.in
curl --fail --location --max-time 30 -o glib-genmarshal.in \
  https://raw.githubusercontent.com/GNOME/glib/2.84.3/gobject/glib-genmarshal.in
sha256sum glib-mkenums.in glib-genmarshal.in
sed -e '1c#!/usr/bin/python3' -e 's/@VERSION@/2.84.3/g' glib-mkenums.in > glib-mkenums
sed -e '1c#!/usr/bin/python3' -e 's/@VERSION@/2.84.3/g' glib-genmarshal.in > glib-genmarshal
chmod +x glib-mkenums glib-genmarshal
```

Expected SHA-256 values (verify before using sources):

| Input | SHA-256 |
| --- | --- |
| `vte-0.84.1.tar.xz` | `aca1caa8478aebcdbb1d67897fb3511eb7601debae6810e16a15b6fa25f31ac8` |
| `glib-mkenums.in` | `dcc4d88bcb3a32174c282dce96124ec96c867d2ec7a85a816a02223c1667e017` |
| `glib-genmarshal.in` | `8691d1119845a6b8e90cfe83a99cd567c8643d62fc5831ea607cf5491a067e81` |

The following are the **literal paths on the measured machine**. Adjust the
private paths for another checkout; never substitute a host install prefix.
The `.pc` source path was confirmed by `pkg-config --variable=pcfiledir glib-2.0`.
If the native development tools are already installed, omit the private script
and `.pc` workaround.

```sh
sed 's|^glib_genmarshal=.*|glib_genmarshal=/home/zoey/Projects/pearl/.cache/coral-terminal-spike/glib-genmarshal|' \
  /usr/lib/pkgconfig/glib-2.0.pc > glib-2.0.pc
PATH=/home/zoey/Projects/pearl/.cache/coral-terminal-spike:/usr/bin:/bin \
PKG_CONFIG_PATH=/home/zoey/Projects/pearl/.cache/coral-terminal-spike \
meson setup vte-build vte-0.84.1 \
  --prefix=/home/zoey/Projects/pearl/.cache/coral-terminal-spike/prefix --libdir=lib \
  -Dgtk3=false -Dgtk4=true -Dapp=false -Dgir=false -Dvapi=false \
  -Ddocs=false -Dglade=false -D_systemd=false --wrap-mode=nodownload
meson compile -C vte-build -j 4
meson install -C vte-build
PKG_CONFIG_PATH=/home/zoey/Projects/pearl/.cache/coral-terminal-spike/prefix/lib/pkgconfig \
  pkg-config --modversion vte-2.91-gtk4
```

`meson install` here writes **only the private prefix**. It also places upstream
profile snippets there; they are never sourced. Meson build logs/configuration
are retained under `vte-build`. If reusing a setup cached before the tool-path
correction, `meson setup --clearcache` was needed on this host.

## Wiring still needed (not performed)

1. Build owner: add an opt-in VTE module/feature and pkg-config detection for the
   **GTK4** package `vte-2.91-gtk4`, never GTK3 `vte-2.91`. Keep normal editor
   builds working without VTE; fail explicitly when the feature is requested but
   unavailable. The measured baseline is 0.84.1, not a promised range of older
   ABI versions. Add standalone native-test targets and CI dependency provenance.
2. Binding owner: use the existing shared GTK module instances; generate/pin VTE
   bindings or maintain this small C ABI deliberately. Do not mix duplicate GTK
   type universes or blindly treat the fixture's opaque `Object` as a production
   type-safe API.
3. App owner: create a real dock/session owner, attach the widget, handle focus
   contexts without intercepting terminal keys/IME, asynchronously publish spawn/
   exit/error states, and retain job/widget state through cancellation. Replace
   fixture control/probe/action instrumentation with proper application lifecycle
   code; **do not wire output to it**.
4. Workspace/trust owner: supply authorized argv, stable root/cwd and explicit env,
   display execution disclosure, and reject untrusted task definitions. Widget
   creation must never itself authorize or spawn a shell.
5. Packaging owner: optional native dependency, tested-version policy and LGPL/
   third-party notices/source compliance. No vendored implementation is proposed.
6. Documentation owner: link this result from the overall status/gate matrix.
   Those shared files were intentionally not edited by this narrowly owned task.

## Explicit limits: M5 remains open

**PTY ownership is not sandboxing or complete interactive job-control
containment.** Existing `ownership.zig` pins the leader/process-group identity
through the final signal, uses a private subreaper, and reaps ordinary descendants
in that group. A process can escape via `setsid`/`setpgid`; interactive shells
routinely create separate foreground/background groups. This fixture deliberately
uses a non-job-control Zig peer and same-group descendants. Neither the successful
cancel test nor the extra supervisor establishes safe cleanup of arbitrary
interactive shell jobs. Escaped descendants can also keep the PTY open and delay
EOF. Kernel-uninterruptible waits can delay cleanup despite the 150 ms TERM grace.

Before claiming M5, choose and test a real session/task containment strategy
(e.g. an appropriately delegated per-session cgroup with explicit policy, or
another audited supervisor design); preserve honest platform limitations. A
cgroup is not by itself a filesystem/network sandbox. VTE's child watcher is not
a solution to that containment gap and must not race Coral's waiter.

Also pending: full shell/job-control flows, in-place restart, tabs/dock/task UI,
workspace trust integration, task output/problem matchers, shell integration,
clipboard/paste and URL policies, physical IME/accessibility, terminal selection,
scrollback/alternate-screen stress and flood responsiveness, font/theme/scaling
matrix, failure/lifetime coverage beyond this bounded fixture, and shipping
packaging. The 1,000-line history limit is not a hard byte/CPU/resource quota.
The selected strategy closes **renderer/embedding feasibility**, not these
production behavior or security gates.
