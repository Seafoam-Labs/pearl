# Pearl implementation progress

## T05 — Complete, September 13, 2026

Session mode now owns wallpaper/bar surfaces per matched GDK/Aqueous connector,
a single modal popup, expiring click-through OSD and invisible frame strips.
Pure logical geometry handles negative origins, mixed scale, rotation and usable
bounds. Bar/frame reservations are unique per edge; GTK's measured bar thickness
updates its zone. Hotplug invalidates monitor mappings and dismisses affected
popups. Escape/outside-click dismissal, OSD focus/input and crash cleanup are
verified with independent application windows in private Aqueous.

`pearlctl` and Pearl control v1 use a per-session Unix endpoint with same-UID
peers, private directories, an instance lock, strict 8 KiB flat frames, eight
clients and five-second deadlines. Stale session and mixed display identities
fail. Pearl also reads the native Aqueous shell capability session on GTK's
actual connection and requires it to match IPC before mapping or claiming the
endpoint. Graceful quit drains its reply; disconnected mutations are not replayed.

Pinned zig-wayland v0.6.0 generates native bindings from vendored/licensed XML.
The GTK Wayland connection remains the sole reader/dispatcher. Actual GTK
surfaces receive rounded blur regions with capability, resize and map/unmap
lifecycle handling. Opaque backgrounds cover absent/disabled effects; Aqueous
namespace vetoes remain authoritative and no user rules are written.

Validation and evidence:

- **36/36 pure tests**, **7/7 adapter unit tests**, and the generated binding API
  test pass on exact Zig 0.16.0, ReleaseSafe.
- **17 acceptance measurements/checks** pass in
  [t05/latest/results.json](../artifacts/t05/latest/results.json), including zero
  idle CPU ticks over 1.5 seconds, SIGKILL reservation release and stale socket
  recovery, duplicate-instance exclusion, eight-client/deadline/frame limits,
  hotplug/rotation and private parent/nested session isolation.
- Native blur is exercised in a Vulkan-effects Aqueous build on the NVIDIA
  RTX 5090. A `pearl:popup` rule veto changes the interior by mean RGB **1.3244**;
  restoring the rule yields **0.0** difference from the enabled capture. The
  protocol trace covers capability loss/re-enable, resized regions, repeated
  remapping, GTK buffer attachment and effect destruction.
- Fresh-cache native binding regeneration matches SHA-256
  `18d6d099fd39f75964bc7bb93bd1b64c2819e33c9e5cfd42d819d52df80cfbc8`.
- Existing lifecycle, Material gallery and all **21 adapter scenarios** pass.
  [Verification logs](../artifacts/t05/verification/) retain the commands' output.

[SURFACES.md](SURFACES.md) documents APIs, ownership, error schema, commands,
reproduction and limitations. Aqueous's private Vulkan teardown reports one
wlroots shared-buffer allocation; Pearl exits without fatal GTK warnings or
protocol errors. Physical output/DPMS/resume, other GPUs and accessibility remain
release-gate work. The popup/bar are explicit T05 primitives, not completed
launcher or control-center services.

**T06 is next:** the first complete desktop slice with real bar groups, launcher,
workspace/window actions, clock/calendar and control-center composition.


## T04 — Complete, September 13, 2026

Implemented two persistent nonblocking GIO sockets using Ghostty's generated
bindings, with same-UID peer checks, paired hello/session validation, subscription,
atomic state publication and exact acknowledgements. Session mode owns the adapter;
the demo gallery remains fixture-only. Sources use generations and monotonic
one-shot deadlines; idle state has no timer or periodic socket traffic.

Typed actions cover window activation/close/state/move, workspace activate/rename,
keyboard set/next, overview and session exit/reload. The bounded queue copies
caller data and validates policy at enqueue and dispatch. Completion distinguishes
applied, accepted, rejected, dropped and unknown. Disconnect invalidates both
channels, drops queued work and never replays sent mutations without a reply.
Backoff reconnects only to the inherited endpoint; a new endpoint needs relaunch.

Window icons have session/revision/size/scale cache identity, command priority,
stale-result rejection, 16 pending entries and 32 cache entries (8 MiB maximum
pixels). A bounded Zig PNG decoder validates RGBA dimensions, CRCs, zlib checksum
and all five filters, skips ancillary metadata, and rejects excess inflation.
Generated GdkPixbuf bindings wrap the pixels without invoking image helpers.

[AQUEOUS_ADAPTER.md](AQUEOUS_ADAPTER.md) documents public APIs, observer/model/pixbuf
lifetimes, deadline/backoff constants, negative caching and reproduction.

Validation and evidence:

- **31/31 pure tests** pass, including every action's strict encoding, copied
  ownership, capabilities, runtime IDs and seat/keyboard policy.
- **7/7 adapter unit tests** pass, covering endpoint boundaries, credential query
  failure, bounded PNG validation and cache limits (plus inherited startup tests).
- **21 protocol/nested scenarios** pass in
  [adapter/results.json](../artifacts/t04/adapter/results.json). Cases include
  byte fragmentation, kernel send-buffer backpressure, bounded queues, one
  outstanding request, invalid ack/sequence/session/ID/order, timeouts, recovery
  with a new session at the same endpoint, no replay, locked/restricted policy,
  target disappearance, ambiguous seat, stale icons, PNG filters/inflation bounds,
  command priority, exact server rejections and lower negotiated request limits.
- Real nested Aqueous verifies workspace rename/activation and config reload
  against queried state, accepted session exit, and refusal to discover a
  replacement compositor's different endpoint. Healthy idle reports no timer;
  scripted peers observe no heartbeat or pipelined requests.
- [Lifecycle regression](../artifacts/t04/lifecycle/results.json) passes with live
  session transport, repeated GTK startup/shutdown, cancellation/drain and fatal
  GTK/CSS warnings enabled. The ordinary application and spike build successfully.

Tests use temporary sockets, private buses and disposable parent/nested compositors.
No host configuration or desktop state is changed. Private PNG fixtures cover
pixel decoding; the live nested checks exercise workspace/session commands rather
than a real application's custom icon publication. Physical multi-seat and lock
integration remain release checks; deterministic peers cover adapter policy now.
**T05 was next at this milestone; see the completed T05 entry above.**

## T03 — Complete, September 13, 2026

Implemented semantic dark/light palettes and scoped Material-style CSS, with
reusable cards, icon buttons, pills, tiles, section rows, switches, sliders and
empty/error/pending states. The maximized, scrollable gallery demonstrates these
components at default/compact density, enlarged text and reduced motion. English
and German catalogs cover labels and accessible names. Eleven original symbolic
SVG icons provide a consistent family without copying DMS font assets.

The gallery uses T02's decoder/reducer for workspace fixtures. Search uses GTK's
filter/selection models and recycling ListView factory over 518 sample entries.
Keyboard actions exercise filtering, sample activation, navigation, toggles,
sliders and workspace pills. Sample interactions remain local to the gallery;
session mode keeps its separate unavailable-services UI. T04 will add transport.

[COMPONENTS.md](COMPONENTS.md) documents APIs, ownership, localization and keyboard
controls. [Side-by-side captures](../artifacts/t03/comparison.html) compare the
gallery with the frozen T00 DMS control-center, launcher and settings references.
Deviations include the native GTK title bar, gallery composition, opaque surfaces,
original icons and this machine's Noto Sans fallback for Inter. Native Aqueous
blur remains T05; the absence of blur in these captures is not a compositor gap.

Validation commands and evidence:

- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe --summary all`:
  **29/29 pure tests pass**, including palette contrast and catalog coverage.
- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-components -Doptimize=ReleaseSafe`:
  [private component suite](../artifacts/t03/latest/results.json) checks keyboard
  search/activation, Unicode case matching, empty results, Tab/Space toggles,
  arrow-key slider adjustment, palette/density/translation changes and 640 px
  enlarged-German reflow. Captured Pango labels show no detected horizontal clipping;
  the 518-item list retains 205 row widgets, including after navigating to its end.
- The idle measurement records **one settling frame in three seconds**, with no
  input injected during that interval. Production gallery code adds no recurring
  timers or frame callbacks; pending indicators remain static.
- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build integration -Doptimize=ReleaseSafe -- --output "$PWD/artifacts/t03/lifecycle"`:
  [lifecycle regression](../artifacts/t03/lifecycle/results.json) passes repeated
  startup/shutdown, cancellation/drain, resource removal and weak-reference
  finalization, including gallery models/factory. Fatal GTK/CSS warnings are enabled.
- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe --summary all`:
  **8/8 build steps succeed** and install the current application/spike.
- `zig fmt --check src/theme src/ui src/core/application.zig src/main.zig src/tests.zig build.zig`: pass.

Tests create private displays, buses and runtime directories. The narrow-layout
check changes only a private headless output. No host configuration or service is
modified. Real screen-reader and physical mixed-DPI checks remain release work.
**T04 is next.**

## T02 — Complete, September 13, 2026

Implemented a pure Zig 0.16.0 NDJSON framer, operation-aware IPC v1 server
decoder, all seven schema-1 entity types and an owned atomic reducer. Candidate
validation covers identity, continuity, references, output/workspace migration,
focus and seat associations. Full replacements clear omitted optional fields;
snapshots replace session-scoped state. Queries provide connector mapping,
per-output sorted workspaces, filtered windows and explicit seat focus.

The codec checks UTF-8, frame/batch/depth bounds, required fields, strict types,
versions, duplicate JSON keys, decimal counters and icon response encoding.
State accounting is bounded across successive deltas. Allocation failure and
validation failure preserve the accepted state without leaking candidate data.
[AQUEOUS_MODEL.md](AQUEOUS_MODEL.md) records API lifetimes, limits and T04 duties.

Ten compacted upstream frames and two explicitly synthetic derived cases are
checked in with a reproducible generator, source/output hashes and GPL-3.0-only
fixture license text. Source inspection used Aqueous revision
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480`; exact hashes also cover the schemas,
protocol prose and serializers. The reference checkout was read only.

Validation actually run:

- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test --summary all`:
  **27/27 tests pass**, Debug, including the existing lifecycle/startup cases.
- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe --summary all`:
  **27/27 tests pass**, including exhaustive representative byte splits,
  malformed prefixes, semantic failure cases and allocation-failure injection.
- `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe --summary all`:
  **8/8 build steps succeed**; existing application/spike compilation was cached.
- `python3 tests/fixtures/aqueous/generate.py --source /home/zoey/RiderProjects/Aqueous --check`:
  **14 fixture/license/provenance files match**.
- `zig fmt --check src/aqueous src/tests.zig build.zig tests/fixtures/aqueous/fixtures.zig`: pass.

No host session, bus or configuration was changed. This task has no visual
changes and does not connect the application to Aqueous; no live transport
test is claimed. T04 will consume this model and own handshake/session matching,
requests, acknowledgements, backpressure and recovery. T03 followed this task;
its completion is recorded above.

## T01 — Complete, September 13, 2026

Added the `pearl` application with explicit session/demo modes, compiled
GResource/GtkBuilder assets, scoped CSS and structured lifecycle logs. The
gallery uses sample content; session mode does not load fixtures or claim a
working service adapter. The application validates launch prerequisites and
reports unsupported desktops, unavailable displays and invalid socket paths.

Shutdown cancels and drains its bounded GTask work before releasing GTK state.
The development launcher creates private headless or Wayland-nested Aqueous
sessions, temporary HOME/XDG directories and private buses. Local launches do
not redirect to a shared application activation name. Verified instance
deduplication and control remain T04/T05 work.

Build targets now include `test` (pure), `test-bindings`, `integration`, `run`
and `gallery`. The application keeps the exact Zig 0.16.0 requirement and uses
the generated T00 bindings. [DEVELOPMENT.md](DEVELOPMENT.md) documents commands,
allocator/GObject ownership, cancellation and main-context completion rules.

Validation:

- ReleaseSafe application build, pure tests and binding tests pass.
- Binding regeneration still matches the pinned inputs.
- The isolated integration suite passes sixteen repeated lifecycles, both
  completed and canceled jobs, GTK close requests, SIGINT/SIGTERM, object
  finalization, resource unregistration, failed compositor-start cleanup,
  invalid environments and concurrent same-display/nested instances. A reused
  bus does not redirect activation. The ordinary executable ignores test hooks.
- Editing an embedded text resource rebuilds the binary; restoring the resource
  reproduces the original binary. The resource compiler's dependency file is
  tracked by Zig.
- The development launcher successfully runs the installed executable in a
  private headless session. The gallery was captured and visually inspected.

Evidence: [results](../artifacts/t01/latest/results.json),
[gallery](../artifacts/t01/latest/gallery.png),
[resource rebuild](../artifacts/t01/resource-rebuild.json).
The private floating parent permits the tested nested startup; a populated
monocle parent stalled in this setup. This is documented as a test-environment
limitation without claiming its upstream cause. No host layout or reference
source was modified. At T01 completion, T02–T16 had not started; the T02 entry
above records the subsequent codec/model implementation.

## T00 — Complete, September 13, 2026

The exact Zig 0.16.0 / Ghostty GTK stack builds and runs against isolated
Aqueous. Full layer-shell and session-lock GIR bindings replace the proposed C
bridge. Their generated GTK parameter types are shared with Ghostty's modules.

Delivered build and generation pins, preserved notices, a minimal GTK/layer/lock
spike, private-session harness, source/hardware metadata, and dark/light DMS
reference captures. [COMPATIBILITY.md](COMPATIBILITY.md) is the handoff for the
next task; [bindings/README.md](../bindings/README.md) explains regeneration.

Checks actually run:

- `zig build -Doptimize=ReleaseSafe` and `zig build test -Doptimize=ReleaseSafe`,
  with `ZIG_GLOBAL_CACHE_DIR` set to the workspace cache: pass.
- `python3 scripts/generate-bindings.py --check`: complete generated file set
  and contents match pinned inputs.
- `python3 scripts/t00.py --idle-seconds 60`: pass, including two-output
  reservation restoration, actual keyboard/pointer behavior, private IPC and
  generated session-lock callbacks. Raw results and screenshots are retained.
- `python3 scripts/t00.py --references-only --output artifacts/t00/dms`: pass;
  16 DMS dark/light captures, including a private notification, pinned fixture
  dock applications, empty media state, settings and lock **demo**.
- `python3 scripts/t00-metadata.py`: recorded revisions, dirty reference status,
  file/library hashes, versions, binding inventory, renderer and machine data.

Keyboard injection uses Aqueous's persistent virtual-keyboard test client:
short-lived `wlrctl keyboard type` did not deliver text in this setup. Pointer
injection still uses `wlrctl`. The final harness disables private-bus automatic
service activation, and temporary sessions are removed on exit.

No production API gap blocks T01/T02. Missing future protocol/service bindings
have explicit implementation paths in the compatibility record. Software-rendered
captures and the test-only lock do not satisfy later GPU, physical-display or
authentication gates. T01 was the next task at this milestone; see its completed
entry above for current progress.

### Blur clarification

Aqueous implements and advertises `ext-background-effect-v1` in Vulkan-effects
builds. T00 explicitly disabled that feature; its registry and screenshots
describe only that test configuration. The compatibility record now identifies
the source gate and runtime capability updates, and T05 explicitly includes
generated protocol bindings and GTK native-blur integration validation. No new
runtime blur test is claimed by this documentation correction.
