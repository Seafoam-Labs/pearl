# T00 compatibility record

Validated September 13, 2026. T00 proves the stack and supplies reference
material; `pearl-t00` is a restricted test executable, not a desktop shell or
authenticated locker. Machine-readable inputs, hashes, linker output and tool
versions are in [metadata.json](../artifacts/t00/metadata.json).

T01 adds the application and development launcher described in
[DEVELOPMENT.md](DEVELOPMENT.md). The evidence below remains the T00 snapshot;
T01 results are stored separately.

## Proven dependency matrix

| Dependency | Tested version / pin | Decision |
| --- | --- | --- |
| Zig | **0.16.0**, native x86_64 Linux, ReleaseSafe | Exact version enforced; no minor-version substitution |
| Ghostty GObject artifact | `gobject-2026-07-28-36-1`, package version 0.3.2 | URL and integrity hash pinned in `build.zig.zon` |
| GIR generator | `jcollie/zig-gobject` commit `4ff7b4d030465b50796b90af72fec41eb9b3b5c6` | Lazy build dependency; same generator used by inspected Ghostty bindings |
| GTK / GDK / GSK | **4.22.5** | Conservative supported floor enforced by pkg-config; earlier releases untested |
| GLib / GIO / GObject | **2.88.3** | Conservative supported floor enforced |
| gtk4-layer-shell | **1.3.0** | Supported floor enforced; includes session-lock monitor API |
| Pango | 1.58.2 | Ghostty module available; GTK text rendering exercised |
| Wayland / xkbcommon / pixman | 1.26.0 / 1.13.2 / 0.46.4 | System dependencies recorded, including shared-library hashes |
| Aqueous compositor | Source `1b1e215285a764cb7e5b605515b784721d68a0a4`; reports 0.6.0 | Own test binary; Vulkan effects and Xwayland disabled |
| wlroots | Aqueous's patched **0.20.2** | Existing source-local build reused; dirty patch inputs separately recorded |
| aqueous-config | **0.7.2**, protocol 1 | `version` and `snapshot --shell none` succeed |
| DMS source | `72ca8a6876b014f5722a00f69301a5766653764e` | Actual QML source used for captures |
| Quickshell / Qt | **0.3.1 / 6.11.2** | Reference capture only, not Pearl dependencies |
| Installed DMS CLI | v1.6.1 | Inventoried; reference capture launches QML directly without the Go backend |

The Aqueous checkout contains existing commit-timing changes. Its revision alone
does not reproduce this machine: metadata records the dirty status, relevant
source hashes and actual binaries/libraries. Reference source trees were not
modified. Normal Pearl builds need the installed runtime/development packages;
exact GIR hashes matter only when regenerating bindings. System package upgrades
are not made reproducible merely by the Zig package lock—use the recorded matrix
or review and revalidate a new one. No CI workflow is installed yet; development
builds enforce `.zigversion`'s exact toolchain through `build.zig`.

## Binding inventory and implementation decisions

Ghostty supplies `gtk4`, `gdk4`, `gdkwayland4`, `gsk4`, `glib2`, `glibunix2`,
`gio2`, `giounix2`, `gobject2`, `pango1` and their dependencies. Its additional
Adwaita, panel, portal, X11 and other modules are inventoried in metadata; Pearl
does not depend on those UI frameworks.

| Missing API | Implementation path / evidence |
| --- | --- |
| GTK layer-shell | **Implemented:** complete `Gtk4LayerShell-1.0` GIR namespace generated as `gtk4layershell1` |
| GTK session-lock | **Implemented:** complete `Gtk4SessionLock-1.0` GIR namespace generated as `gtk4sessionlock1`; real monitor/locked/unlocked callbacks exercised |
| Aqueous layout | **Implemented in T06:** generated window-info manager v3 query/set requests on GTK’s verified display; refresh on demand/active-workspace change, no continuous external layout observation |
| Idle, data-control and capture protocols | Generate Zig protocol bindings from pinned XML when their tasks begin; no handwritten wire marshalling |
| libpulse | **Implemented in T07:** translate pinned 17.0-98-gb096 headers with Zig 0.16.0; GLib main-loop adapter, no C bridge |
| PAM | Generate direct Zig ABI declarations from pinned headers when its task begins; no custom C bridge |
| Polkit agent | Generate its missing GIR namespace using the same workflow; authentication behavior remains T12 work |
| Native background blur | **Implemented in T05:** generated `ext-background-effect-v1` on GTK’s existing display/surfaces. Private Vulkan tests verify native blur, namespace veto, capability changes, resizing and remap; see [SURFACES.md](SURFACES.md) |

[Binding instructions](../bindings/README.md) describe regeneration and notices.
Generated modules reuse Ghostty's GTK type identities. The compiled API test
checks both window parameter types, enums and declaration availability. The
integration test checks live behavior beyond compilation. ELF `DT_NEEDED` lists
`libgtk4-layer-shell.so.0` before `libgtk-4.so.1`; the layer-shell probe reports
supported, protocol 4, library 1.3.0, and session-lock monitor API present.

### Native blur support versus the T00 test build

Aqueous supports `ext-background-effect-v1`. In the inspected source,
`compositor/aqueous/BackgroundEffectManager.zig:init` creates its v1 global when
`fx.blur_available` is true; `fx.zig` defines that flag from `vulkan_effects`.
T00 explicitly built with **`-Dvulkan-effects=false`**, so its saved registry
cannot establish blur availability in the normal Vulkan-effects build.

Protocol presence and current blur capability are separate: the manager sends
capability updates based on global blur enablement and positive radius/passes.
Pearl now consumes those updates and requests per-surface blur regions through
the native protocol. A matching layer rule is not required for native main-layer
blur; explicit deny rules and the documented popup policy still apply. Keep
user-authored rules intact. An opaque fallback covers unavailable or disabled
effects, not a presumed lack of Aqueous support.

Aqueous already supplies `compositor/scripts/test-background-effect.py` and
`docs/dms-integration-testing.md` covering its native protocol and real DMS blur
components. Those informed Pearl's GTK integration test; they were not run as part of T00.
T05 evidence is separate from this historical no-effects baseline.

## Aqueous capabilities observed

[hello.json](../artifacts/t00/latest/hello.json),
[snapshot.json](../artifacts/t00/latest/snapshot.json) and
[wayland-info.txt](../artifacts/t00/latest/wayland-info.txt) are actual private
session responses.

- IPC/schema 1; two connections return the same session. Subscribe, initial
  delivery and acknowledgement succeed. Advertised capabilities include state,
  commands, keyboard, overview, shortcut inhibition, icon metadata/fetch and
  configuration reload. Advertisement does not mean every command was tested.
- Limits: request 65,536 bytes, frame 4,259,840, state 2,097,152, batch 4,194,304,
  depth 16, one pending request, 16 clients. T02 must implement the complete
  bounded parser/reducer; the Python spike client is not production transport.
- `session.reload` returns `status: applied`. Runtime layout is separate:
  `aqueousctl layout` queries monocle, changes to grid, then restores monocle
  through `aqueous_window_info_manager_v1` v8.
- GDK connector identities exactly match IPC outputs on both headless monitors.
  Each is 1280×720 at scale 1, positioned at x=0 and x=1280. These have no EDID or
  physical dimensions and advertise refresh 0; they do not model physical refresh.
- Registry includes standard layer-shell v4, session-lock v1, output management
  v4, data-control, idle notifier v2, idle inhibition, shortcut inhibition,
  ext-workspace, and output/toplevel capture-source protocols. Capture advertisement
  alone is not proof of isolated-window capture. `aqueous_layer_shell_v1` belongs
  to the external-WM path and is not Pearl's layer-shell API.
- `aqueous-config --shell none` advertises generation checks, stdin requests,
  atomic replacement, live outputs, monitor modes/mirroring/scale, rules and
  keybindings. No helper apply or host settings mutation was performed.
- The private session initially owns only its D-Bus daemon and probe connection.
  System bus access is pointed at a nonexistent private socket. Audio, network,
  Bluetooth, power and authentication services therefore remain untested here.
  `/sys/class/backlight` is empty on this desktop: brightness needs an explicit
  unavailable state; DDC remains optional future work.

## Reproduce

Install the matrix above plus Python 3, a C compiler and Wayland scanner for
Aqueous's existing **external test input client**, `dbus-run-session`, `busctl`,
`wayland-info`, `wlrctl`, and `grim`. Binding regeneration additionally needs
`xsltproc` and locked GIR files. DMS captures need Quickshell, its QML imports,
the DMS checkout with its common submodule, and `notify-send`.

Build Pearl from the repository root:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build -Doptimize=ReleaseSafe
zig build test-bindings -Doptimize=ReleaseSafe
python3 scripts/generate-bindings.py --check
```

The Aqueous test binary was built with the existing patched wlroots installation:

```sh
PKG_CONFIG_PATH=/home/zoey/RiderProjects/Aqueous/compositor/.deps/wlroots-render-hook/lib/pkgconfig \
zig build --build-file /home/zoey/RiderProjects/Aqueous/compositor/build.zig \
  --cache-dir "$PWD/.cache/aqueous-build" --prefix "$PWD/.cache/aqueous" \
  -Dvulkan-effects=false -Dman-pages=false -Doptimize=ReleaseSafe -Dllvm
```

On another machine, prepare the pinned Aqueous source and patched wlroots in a
separate development checkout using its `scripts/build-wlroots-render-hook.sh`.
Point pkg-config at that installation; source and binary hashes will differ if
the recorded local patch changes are absent. The harness accepts `--aqueous`,
`--ctl` and `--aqueous-source` overrides.

```sh
python3 scripts/t00.py --idle-seconds 60
python3 scripts/t00.py --references-only --output artifacts/t00/dms
python3 scripts/t00-metadata.py
```

The harness creates private HOME/XDG directories, a headless Aqueous compositor
and a private D-Bus daemon with no service activation directories. It passes only
its own display/socket to clients, never imports the host service-manager
environment, and terminates its child process groups. Sandboxes that prohibit
Unix socket creation must allow this isolated harness to run outside that
restriction. The existing Aqueous C input fixture is compiled into the temporary
directory as a separate executable; it is not a Pearl binding or bridge.

Use separate `--output` paths for simultaneous runs. The harness replaces files
in its selected output directory. `pearl-t00` refuses an ordinary host session;
use `scripts/t00.py` for this spike. Since T01, `zig build run` launches the new
application through its private development harness.

## Evidence and limits

[results.json](../artifacts/t00/latest/results.json) records a passing run:
normal GTK window, bar on two outputs, 48px reservations, focused popup text
`aqueous`, Escape, outside-click dismissal with no underlying click, a subsequent
click reaching the underlying application, and graceful unmap restoring both
outputs to 720px usable height. The generated lock API reports both monitors,
acquires the isolated lock, and releases it with corresponding compositor state.
It has no authentication and must not be reused as the production locker.

On the AMD Ryzen 9 9950X3D / 32-thread reference machine, ReleaseSafe spike bar
readiness was **30.56 ms** from process launch to observed reservations. A single
**60-second** idle sample measured **0 CPU ticks** and **16,091 KiB PSS** after the
interaction/lock probes. This accounts for the bar process only and proportional
shared mappings; it excludes the compositor, test client and normal-window
process. Readiness is not frame-presentation timing or p50/p95. The small spike
has no real service workload, so these are not full-shell performance claims.

The machine has NVIDIA RTX 5090 and AMD integrated GPUs, but these runs used
wlroots pixman, GTK cairo and Qt software. GPU rendering/blur, physical input,
mixed/fractional scales, hotplug, accessibility, authentication, locker failure,
service lifecycle and sustained full-shell performance remain the later tasks'
validation gates. See the [visual reference index](../artifacts/t00/REFERENCES.md)
for captured surfaces and reference-specific limitations.


## T05 surface and Vulkan-effects validation

[T05 results](../artifacts/t05/latest/results.json) record the tested Pearl,
pearlctl and effects-compositor binary hashes. The effects binary uses Aqueous
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480`, patched wlroots and
`-Dvulkan-effects=true -Dllvm`, on the NVIDIA RTX 5090. The test compositor uses
Vulkan; GTK uses cairo buffers. This is real native blur on GTK layer surfaces,
including a measurable pixel difference under a namespace veto and exact pixel
restoration after removing it. Global capability disable produces opaque panels.

The suite also passes two-output scale 1/1.5 and negative-origin placement,
rotation, output disable/re-enable, reservations, input/focus, popup arbitration,
SIGKILL cleanup, stale socket recovery and private nested CLI isolation. Aqueous
native display session identity is checked against IPC before creating surfaces
or a control endpoint. All sessions and rule/config changes are private.

Native XML inputs and zig-wayland **v0.6.0** output are pinned in
[inputs.json](../bindings/protocols/inputs.json); fresh-cache regeneration matches.
See [SURFACES.md](SURFACES.md) for reproduction and the wlroots teardown allocation
diagnostic. This evidence does not cover physical DPMS/resume, other GPUs,
HDR/VRR, accessibility or production GPU performance.


## T06 live desktop validation

[T06 preview results](../artifacts/t06/latest/results.json) record the final
Pearl/pearlctl hashes, 2,000-application search and warm opening timings. GIO
semantics are exercised through real temporary desktop files, independent GTK
applications, a private terminal stub and private D-Bus activation. Duplicate
window titles/workspace numbers, effective keyboard state, exclusion/minimized
hints, application install/removal, empty/localized catalogs, native layout
query/set and 100/125/150/200% scale pass the preview gate.

The Aqueous revision and toolkit floor remain unchanged. T06 adds Ghostty's
`giounix2` module and two pinned XML inputs, preserving their copyright/license
notices. No new custom C bridge or compositor modification is used. The borrowed
GTK display already passes T05's native-session/IPC identity check. One-shot
layout semantics and remaining external-observation limits are documented in
[DESKTOP.md](DESKTOP.md). [The visual comparison](../artifacts/t06/comparison.html)
uses actual DMS/Pearl captures and records deliberate feature/layout differences.


## T07 service validation

The [service contract](SERVICES.md) records the implemented audio/power behavior
and physical release checklist. Dependencies added for normal builds are
`libpulse` and `libpulse-mainloop-glib`, tested at **17.0-98-gb096**. The private
integration fixture uses installed **PipeWire 1.6.8**, synthetic null sinks,
playback/recording clients, separate D-Bus buses and a fake UPower/logind/profile
peer. It does not load hardware monitor modules. No host audio or power service
was used for mutations.

[Results](../artifacts/t07/latest/results.json) verify delayed writes, permission
denial, device removal, defaults, channel balance, modern/legacy profiles, daemon
and bus recovery, keyboard power confirmation, OSD replacement/focus and shutdown
with pending work. Physical backlight/battery/power checks remain open; this
machine's `/sys/class/backlight` is empty. Suspend/lock/inhibitor handling remains
T12. [Header pins](../bindings/headers/inputs.json) and
[verification records](../artifacts/t07/verification/README.md) retain generated
ABI identity, binary hashes and regression evidence.
