# Pearl implementation progress

## T13 — Implemented, September 13, 2026

Completed the native lock interface and lifecycle work built on T12. The locker
now scales with Pearl’s text setting, scrolls on small outputs, prioritizes the
account card on short displays, labels each PAM prompt for accessibility,
announces status/Caps Lock changes and supports keyboard cancellation/retry.
It uses GTK’s secure entry buffer and rejects oversized UTF-8 or ASCII responses
instead of authenticating a truncated prefix.

Queued, coalesced monitor assignment avoids the reentrant mapping sequence found
in the pinned GTK session-lock library during burst hotplug. Removed views clear
their response and release their references; returned outputs focus the current
prompt. Readiness descriptors are validated before GTK can reuse their number
for a display socket. Helper failure, timeout, cancellation and malformed frames
remain locked. The clock updates independently at minute boundaries, with a
one-shot retry cooldown instead of full UI updates every second.

Checks: 92 pure/adapter/binding tests; 15 dedicated native-lock scenario groups;
20 session-security regression groups, including SIGKILL of Pearl while its
locker remains usable. The dedicated suite records 100 settled reconnects,
12 burst reconnects, all-output removal/return, mixed-scale/rotated and sole
small-display input, GTK accessible-label and secure-buffer checks, PAM helper
failure recovery, and a 65-second idle CPU/memory/descriptor sample.

[T13 evidence](../artifacts/t13/README.md) records binaries, sources, screenshots,
resource measurements and validation logs. [LOCK_SCREEN.md](LOCK_SCREEN.md)
describes implementation details and the pinned library mitigation. Production
build/staging, test-hook exclusion, formatting and syntax checks pass. No host
PAM policy or service was changed.

Implementation is complete with physical acceptance pending: real hardware
DPMS/lid/suspend/resume, mixed-DPI hotplug timing, screen-reader speech/AT-SPI,
and installed distribution PAM/fingerprint/smart-card policy. The recorded
bounded soak is not a claim about an indefinite run. T14 is next.

## T12 — Implemented, September 13, 2026

Implemented Aqueous session actions, AC/battery idle policy, logind inhibitor and
resume coordination, and a session-scoped polkit authentication agent. The user’s
Noctalia clarification brings the native `pearl-lock` foundation forward from
T13: a separate Zig/GTK process owns real session-lock surfaces, with clock/date,
account card, shared Material or GTK theme, and a separate Linux-PAM conversation
helper. There is no swaylock or other external-locker production path.

Pearl requires both the native protocol acknowledgement and current Aqueous
locked state before requesting sleep. Failure, cancellation and false readiness
remain locked or prevent Pearl-initiated sleep. Confirmed logout drains GTK and
services before closing Wayland and requesting exit over verified Aqueous IPC.
The polkit panel checks the authority sender, supports multiple Unix identities,
and cancels on authority/session loss, lock, Escape or timeout.

Full Polkit/PolkitAgent namespaces share Ghostty GTK/GIO types; idle protocol
bindings and pinned PAM header translation extend the existing generated stack.
The staged package includes the native locker, user unit and Arch-style PAM
policy; no host unit or PAM configuration was changed.

Verification: 91 unit/adapter/binding tests; 19 private security scenarios;
21 preferences, 15 audio/power and 12 application-lifecycle regression groups.
Builds use Zig 0.16.0 ReleaseSafe. GIR, Wayland and PAM regeneration checks,
production test-hook exclusion, staging, formatting and whitespace checks pass.
Material dark/light and GTK lock captures were inspected. Evidence and exact
limits: [T12 verification](../artifacts/t12/README.md).

[SESSION_SECURITY.md](SESSION_SECURITY.md) documents controls, policy, packaging,
recovery and physical acceptance. Actual hardware suspend/lid/resume, mixed-DPI
hotplug, distribution PAM policies and real system polkit authorization still
need installation-specific validation. This completes T12 implementation; T13’s
remaining hardware, accessibility and long-run acceptance is explicitly pending.

## T11 — Implemented, September 13, 2026

Replaced the old Aqueous settings frontend directly with Pearl GTK pages over
`aqueous-config --shell none`, using Zig 0.16.0 and the pinned Ghostty bindings.
All 221 helper fields are mapped; the six raw files and collection requests are
available in Advanced. Dedicated visual rule/custom-binding/snap editors and
unsupported display properties are explicitly deferred in the
[field inventory](AQUEOUS_FIELD_INVENTORY.md).

One worker owns immutable request/snapshot copies. Helper calls have bounded
stdin/stdout/stderr, process-group cleanup and deadlines. Validation retains the
original generation; drafts survive popup destruction, invalid input, external
changes and edits during active jobs. Conservative rebasing preserves conflicts.
Uncertain saves trigger read-back without replay. Canonical save, acknowledged
reload and toolkit target synchronization have separate outcomes. Reload can be
retried independently of saving. Raw display changes cannot bypass protection.

The separate display guardian uses generated output-management v4 bindings. It
tests before applying, holds a 15-second Keep/Revert lease, and persists only after
Keep revalidates the helper generation and live state. Parent death and timeout
revert only unchanged candidate heads. Competing edits and output removal preserve
unrelated live state. Mirror/HDR/profile/enable-disable/custom-mode and raw display
policy edits remain gated where the helper/protocol cannot prove safe preview.
Physical monitor validation is not claimed by virtual-output tests.

Shortcut recording waits for acknowledged GDK inhibition and releases it on
cleanup/revocation/deadline. Private tests verify a compositor binding is
suppressed while recording and restored afterward. All GTK signal handlers are
disconnected before releasing their callback data, including notebook/focus
objects retained during teardown.

Verification: **87 unit/binding tests and 74 integration checks/groups** covering
T11 (24), T10 preferences/themes (21), surfaces/blur/control (17), and lifecycle
(12). See [the evidence report](../artifacts/t11/verification/README.md) and
[actual dark/light/native GTK captures](../artifacts/t11/comparison.html).

## T10 — Complete, September 13, 2026

Implemented versioned Pearl preferences, settings pages, wallpaper, dynamic
Material palettes and the additional native GTK theme mode in Zig 0.16.0.
Static Material remains usable without matugen. GTK mode follows normal GTK
settings or an installed GTK4 theme, including its controls and surface styles;
Material overrides are removed from those roots. Native Aqueous blur remains
supported, with opacity supplied by the selected theme.

One bounded GTask worker validates and prepares configuration, wallpaper and
palette changes. A main-thread CSS check precedes atomic persistence and a shared
provider/texture swap across output surfaces. Matugen receives a private empty
configuration, dry-run argv, bounded pipes and a deadline; obsolete loads are
cancelled and processes are reaped. Eight cache slots use validated role colors
and input/mode/generator identity. There is no recurring theme work at idle.

Typed validation and migration, etag/content conflict checks, atomic first
creation/replacement, directory monitoring and a last-good snapshot preserve
working settings. Settings drafts remain in memory through popup close, output
changes and external edits. Three-way merging combines disjoint fields and keeps
overlapping conflicts for review. Bar groups/edge/size can differ by connector;
fonts, density, popup placement/limits/dismissal and wallpaper fit are live.
Opt-in text exports require ownership hashes and keep a first-replacement backup.

Verification: **74 unit/binding tests and 125 integration checks/groups pass**,
including 21 T10 groups. The T10 suite uses real GTK keyboard editing, draft
close/reopen/merge/apply, real matugen output, custom GTK theme pixel checks,
corrupt/large/legacy files, CSS rejection, missing fonts/images/themes, failed
saves, reservation conflicts, cross-output OSD styling, export ownership, cache,
idle behavior, generator failure/deadline/cancellation, concurrent edits and
restart recovery without matugen. Desktop, notifications/tray/media, audio/power,
connectivity, surfaces/native blur, and lifecycle/isolation regressions pass.
All suites match the final production/instrumented binaries; see
[T10 verification](../artifacts/t10/verification/README.md) and
[unedited captures beside DMS](../artifacts/t10/comparison.html).

[PREFERENCES.md](PREFERENCES.md) documents the schema and limits. GTK themes must
support GTK4; wallpaper currently accepts bounded local regular PNG/JPEG files.
One wallpaper is shared across output surfaces, and drafts survive popup closure
but not process exit. Exports are generated in Pearl's owned export directory
for consumers to include/link explicitly. The settings UI uses tabbed pages and
an Advanced editor; it does not yet provide the full future sidebar/search UI.
Aqueous's settings helper/frontend belongs to **T11, the next numbered task**.
No host theme, wallpaper, radio, daemon ownership or Aqueous configuration was
changed. T08's physical scan acceptance remains pending.

## T09 — Complete, September 13, 2026

Implemented notification, StatusNotifier/DBusMenu and MPRIS services in Zig 0.16.0
using the pinned Ghostty GIO/GTK bindings. Notification replacement, exact action
keys, resident/transient behavior and closure reasons are verified by real
private protocol clients. A bounded, grouped in-memory history and DND accompany
independent non-keyboard toast surfaces. Actual Aqueous lock/unlock suppresses
content and actions without replaying locked deliveries.

The bar renders tray pixmaps/icons and exposes overflow. A watcher/host follows
registration and unique owners, cooperates with an existing watcher, and renders
nested DBusMenu entries with toggle, visibility and sensitivity state. Media
cards offer player selection, capability-aware controls and track-bound seeking.
Progress timers belong to open playing views. One cancellable artwork worker
accepts bounded local PNG/JPEG files; remote URLs intentionally use a fallback.

Existing notification/tray service names are never replaced. A private session
bus restart exposed GApplication retaining a closed shared GIO connection; the
service transport now creates an independent connection for reconnects. Owners,
menu revisions and transport epochs reject stale replies and user actions.
A blur regression also exposed actual Aqueous configuration-reload notifications;
that pixel experiment now enables DND to isolate its blur variable.

Verification: 70 tests across the pure, adapter and binding test binaries;
18 private T09 groups including real GTK keyboard actions, seek edits surviving
progress ticks, nested menu navigation, real lock/unlock, owner churn, limits,
production ownership conflicts and session-bus restart. Existing connectivity,
audio/power, desktop, surface/blur and lifecycle suites pass. Exact counts,
binary/source hashes and logs are recorded in [T09 verification](../artifacts/t09/verification/README.md).
[Actual captures beside DMS](../artifacts/t09/comparison.html) cover history/toasts,
media and nested tray menus. The protocol/CLI contract and supported limits are
in [SESSION_SERVICES.md](SESSION_SERVICES.md).

T10 was next at this milestone; see its completed entry above. T08's physical scan acceptance remains pending;
no host Wi-Fi/Bluetooth state was changed for T09.

## T08 — Implemented; physical scan acceptance pending, September 13, 2026

Implemented NetworkManager and BlueZ through the pinned Ghostty GIO bindings in
Zig 0.16.0. The control center now has adapter, network, saved-profile and Bluetooth
device lists, masked authentication prompts, pending/cancel/error states and a
GIO handoff to the network editor. The default bar includes live network state;
Bluetooth is an optional configurable group.

NetworkManager supports open/WPA-personal/WPA3-SAE activation, saved Wi-Fi/wired
profiles, disconnection, radio state and bounded explicit scans. A registered
SecretAgent answers only matching user-initiated requests from the daemon's unique
owner. Temporary new profiles disable autoconnect and mark passwords not saved.
Pearl never persists credentials or accepts them through CLI arguments. Existing
saved profiles retain NetworkManager's storage policy.

BlueZ has a client-local KeyboardDisplay Agent1 with PIN/passkey entry, passkey
confirmation/display, authorization, cancellation and release. Pairing, trust and
connection are separate actions. Discovery has a 30-second lease, including cleanup
when its start reply arrives after the panel closes. Owner/bus changes cancel old
calls and rebuild agents; oversized snapshots fail closed. Authentication widgets
clear sensitive contents and reveal their full action row after allocation.

A keyboard regression exposed GTK traversing the detached ScrolledWindow child
of a collapsed expander. Explicit child visibility now follows expansion, and
real GTK navigation through closed/open lists and the existing power controls is
covered. [Implementation contract](CONNECTIVITY.md) documents API ownership,
limits, unsupported authentication, cancellation and the status/action CLI.

Verification: 58 pure/adapter/binding tests; private connectivity conversations
and existing audio/power, desktop, surface/blur and lifecycle suites. Final exact
counts, source/binary hashes and logs are in [verification](../artifacts/t08/verification/README.md).
[Actual captures beside DMS](../artifacts/t08/comparison.html) show the network
list, credential rejection and Bluetooth pairing UI.

Physical read-only validation found the real Wi-Fi adapter (radio off), registered
both agents and observed the connected Bluetooth headset without changing its
connection or the Wi-Fi radio. A concrete opt-in scan script is ready at
`scripts/check-connectivity-hardware.py --scan`; it temporarily enables Wi-Fi,
scans, briefly discovers Bluetooth and restores Wi-Fi. Enabling Wi-Fi can cause
NetworkManager to autoconnect a saved profile. User approval for this host state
change is pending, so **T08's physical scan acceptance is not marked complete**.
Actual physical secure association/pairing has not been claimed from fake tests.

T09 proceeded on its T06 dependency; the separate T08 physical scan gate remains pending.

## T07 — Complete, September 13, 2026

Implemented libpulse audio through generated Zig declarations and the GLib main
loop: devices, playback/recording streams, defaults, channel-preserving volume,
mute and routing. Bounded queues coalesce rapid changes while preserving writes
received during an in-flight operation. Default changes retain captured target
identity; server loss drops old mutations and reconnects with a new generation.

UPower supplies battery state; logind supplies active-session and power-action
availability plus validated brightness writes. Modern and legacy power-profile
services expose only advertised profiles. D-Bus requests target unique owners,
validate reply types and drain safely through service/bus restart and shutdown.
Backlight discovery runs in a worker; permission denial and missing readback stay
visible without claiming success. Physical brightness/power tests remain explicit
release checks. Suspend/lock/inhibitor orchestration remains T12.

The control center now contains these live services, with audio/battery bar
groups. Power off and restart require two deliberate activations of the same
button within ten seconds; cancellation, expiry and owner changes invalidate
confirmation. OSD coalesces service feedback and reuses one non-focusable,
click-through surface, label and expiry timer. Sliders retain displayed intent
until authoritative readback arrives.

Validation and evidence:

- **54/54 unit and binding tests** pass on exact Zig 0.16.0, ReleaseSafe:
  46 pure tests, seven adapter tests and one generated binding API test.
- **15 service acceptance groups** pass with separate private buses, synthetic
  PipeWire/Pulse devices, real playback/recording clients and a delayed/denied
  UPower/logind/profile peer. Coverage includes in-flight final-value retention,
  balance, defaults, device removal, daemon/bus recovery, legacy profiles, real
  GTK keyboard confirmation, denial/acceptance, OSD reuse and pending shutdown.
- Desktop (**15 groups**), surfaces/native blur (**17 checks**) and lifecycle
  (**12 checks**) regressions pass. No host audio, physical brightness or physical
  power operation was used by these tests.
- Fresh-cache libpulse generation matches SHA-256
  `14ceb08f4aa8e64533eaef3e748ccd4b1ce74c969912723641049cc2e28c2a74`.
  Pinned public headers and the opaque GLib type shim contain declarations only;
  no C bridge was introduced.

[SERVICES.md](SERVICES.md) documents APIs, bounds, permissions and physical
release checks. [Visual evidence](../artifacts/t07/comparison.html),
[service results](../artifacts/t07/latest/results.json) and
[verification records](../artifacts/t07/verification/README.md) retain actual
captures, fixture behavior, commands and binary identities.
**T08 was next at this milestone; see the implementation entry above.**

## T06 — Complete, September 13, 2026

Session mode now has configurable bar groups, live per-output workspaces and
focused titles, effective keyboard layout, clock/calendar, a real application
and running-window launcher, overview and control-center composition. Workspace
and window actions use authoritative runtime IDs, including duplicate labels
across outputs. Overflowing workspace strips reveal the newly active workspace.

GIO owns desktop discovery and launch semantics, including localized metadata,
visibility, desktop actions, field codes, working directories, terminal and
D-Bus activation. A monitored immutable catalog feeds bounded asynchronous
Unicode search and a virtualized result list. Session/generation validation,
stable selection identity and cancellation/drain protect refresh and teardown.

Generated native Aqueous bindings query and set runtime workspace layout on
GTK's verified Wayland connection. The control center exposes these real layout
controls; future audio, network, brightness and media services show unavailable.
External layout changes on the same workspace require Refresh because Aqueous
does not continuously publish them. Bar preferences and recent applications are
currently in memory; persistent settings remain T13 work.

Validation and evidence:

- **49/49 unit and binding tests** pass on exact Zig 0.16.0, ReleaseSafe
  (41 pure, seven adapter and one generated API test).
- **15 desktop acceptance groups** pass in
  [desktop results](../artifacts/t06/latest/results.json): real GIO launches,
  duplicate identities, keyboard/workspace/window actions, native layout,
  install/removal, empty catalogs, German labels, long text, mixed scale and
  pending-search teardown.
- With **2,000 applications**, 132 search-to-paint measurements have median
  **12.8 ms** and p95 **28.3 ms**. Eight warm launcher openings have median
  **37.6 ms**, maximum **49.9 ms**, including CLI/status observation overhead.
  These are private headless measurements, not physical input/display latency.
- All **17 surface checks** pass on the final desktop binary, including native
  Vulkan blur, focus/input, reservations, hotplug and session isolation. Monitor
  property observation fixes GDK connectors arriving after list insertion.
- Existing lifecycle, Material gallery and **21 adapter scenarios** pass.
  [Verification records](../artifacts/t06/verification/README.md) identify suite
  binaries, commands, logs and the final workspace-scroll follow-up.
- Fresh-cache native binding generation matches SHA-256
  `c1cfb6bbd6ff33e83e18ca9f73e095fe9f6c1f10e5825f2f38ef92bc0ac16fdf`.

[DESKTOP.md](DESKTOP.md) documents implementation, commands and limits.
The [visual comparison](../artifacts/t06/comparison.html) pairs actual Pearl
captures with the frozen DMS reference and records deliberate scope differences.
Tests use private sessions without changing the host desktop. Physical-display
performance, extended soak, full service coverage and accessibility remain later
release gates. **T07 was next at this milestone; see the completed entry above.**

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

**T06 was next at this milestone; see the completed T06 entry above.**


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
