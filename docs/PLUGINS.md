# Pearl plugins (experimental)

New to writing plugins? Follow the [plugin development guide](PLUGIN_DEVELOPMENT.md)
to build, install and test a clickable counter before adding more features.

Pearl now runs language-neutral WebAssembly components in a separate
`pearl-plugin-host` process per enabled plugin. The experimental interface is
[`pearl:plugin@0.1.0`](../plugins/wit/plugin.wit). C, Zig and freestanding Rust
examples use the same interface and have been exercised against the real helper.
Ordinary core Wasm, arbitrary WASI programs and native shared libraries are not
Pearl plugins.

Plugin management is available in **Pearl Settings → Plugins**, exclusively in
the main application. `pearl-settings --page plugins` and
`pearlctl settings show --page plugins` open it. The compact flyout rejects this
route and contains no plugin controls or plugin shortcut.

## Build

Use Zig 0.16.0 and the official Wasmtime **48.0.2 C API** archive for the target
architecture. The build translates its headers and statically links its runtime
into the isolated helper. Pearl and Settings do not link Wasmtime. No developer
machine library paths are embedded in the helper. The official x86_64 archive
and verified checksum are recorded in the [probe instructions](../spikes/wasm-plugins/README.md).

```sh
zig build -Doptimize=ReleaseSafe -Dwasm-plugins=true \
  -Dwasmtime-prefix=/absolute/path/to/wasmtime-v48.0.2-x86_64-linux-c-api
```

The switch defaults to false while the interface is experimental. Builds without
it preserve plugin preferences, display unavailable runtime status and need no
Wasmtime headers or libraries. Use separate install prefixes when comparing
build variants, to avoid packaging stale output from a previous build.
`packaging/install.sh` stages the optional helper, runtime license and WIT SDK;
Git packages rename the helper to `pearl-plugin-host-git` alongside `pearl-git`.
The release, Git and Intel Git Arch packages enable the runtime and build and
install all four examples into `/usr/share/pearl/plugins/` (release) or
`/usr/share/pearl-git/plugins/` (Git variants). After installing/upgrading the
package, restart Pearl to see them in main Settings → Plugins. They remain
disabled until you approve and enable them; installation does not change your
preferences or add bar widgets.

The PKGBUILDs fetch checksum-pinned Wasmtime 48.0.2, wit-bindgen 0.62.0 and
wasm-tools 1.259.0 archives. They use Arch's `rust` and `rust-wasm` build packages
and prefetch locked Cargo dependencies in `prepare()` for the offline example
build. Only the four examples, cat artwork/license, WIT SDK and runtime helper
are installed; build tools and failure fixtures are excluded.

For manual staging, set `PEARL_PLUGIN_EXAMPLES_DIR` to the built examples root
when running `packaging/install.sh`. Leaving it unset stages no examples.

## Build and install examples

The SDK build script downloads nothing. Provision Zig 0.16.0,
[wit-bindgen 0.62.0](https://github.com/bytecodealliance/wit-bindgen/releases/tag/v0.62.0),
[wasm-tools 1.259.0](https://github.com/bytecodealliance/wasm-tools/releases/tag/v1.259.0),
`rsvg-convert`, and a Rust toolchain with `wasm32-wasip2`.
The tested Rust compiler is 1.96.0. Prefetch the Cargo.lock dependencies into
`.cache/plugin-cargo` with `cargo fetch --locked --manifest-path
plugins/examples/counter-rust/Cargo.toml` and `CARGO_HOME` set to that directory.

```sh
python3 plugins/build-examples.py \
  --wit-bindgen /absolute/path/to/wit-bindgen \
  --wasm-tools /absolute/path/to/wasm-tools --fixtures
```

Outputs are under `.cache/plugin-examples/`. The `timer-c`, `counter-zig`,
`counter-rust` and `companion-c` directories are complete packages. The `fault-*`
directories are test fixtures; do not install them for everyday use.

Copy each desired package to `$XDG_DATA_HOME/pearl/plugins/<directory>` (normally
`~/.local/share/pearl/plugins/<directory>`), then restart Pearl to discover it.
System packages can use the installation's `share/pearl/plugins/` directory
(`share/pearl-git/plugins/` for Git builds). One optional version-directory level
is supported. Packages must contain regular files; symlinked members are rejected.
The user discovery root has priority over duplicate system IDs and versions.
Discovery does not execute any plugin.

Open Plugins, review the package fingerprint and requested permissions, choose
**Approve package**, then enable it and **Apply & save**. **Add to bar** adds its
reference to the right bar group in the draft. Bar references have the form
`plugin:pearl.timer-c/main`; they may also be entered in Bar & dock or per-output
preferences. Unknown references remain harmless until a matching plugin runs.
The native launcher remains mandatory.

Schema controls support text, bounded integer and boolean values. Enablement,
approvals, permissions, settings, and placement share Pearl's retained draft,
Apply, Discard and conflict workflow. Missing packages retain their configuration
and can be disabled. Independent plugin records/settings merge by identity;
concurrent changes involving a different approved fingerprint require review.
Retry restarts an existing approved package; Preview sends a synthetic event.
Both act immediately. Changed package bytes cannot reuse an old approval;
restart Pearl to rediscover updated content and approve the new fingerprint.

## Companion and overlays

Pearl Cat includes original CC0 artwork, PNG sprite frames and one-shot poses.
It runs in a bar or, with the overlay grant, in a managed desktop overlay.
The renderer owns GTK widgets, PNG decoding and frame-clock animation. There is
no guest invocation per animation frame. Reduced motion stops playback.

Overlay placement supports output connector, logical size/position, position
locking, click-through, interaction and fullscreen hiding. An empty output
selects the first active output. Unlocking placement enables pointer input;
dragging the overlay saves a bounded position if no Settings draft is pending.
When a draft is pending, use its position controls instead. Overlays reserve no
screen space, request no keyboard focus, and disappear before lock/authentication
or inactive-session transitions. Output removal tears down associated views.

**Pearl Cat can react to typing and mouse-button presses in other applications.**
Approve and enable the package, turn on **Allow keyboard and mouse activity** in
main Settings → Plugins, then Apply. Use the matching Aqueous Pearl integration
service described in [activity setup](AQUEOUS_PLUGIN_ACTIVITY.md).

`input-activity(true)` records a plugin's subscription request. Its manifest and
saved grant must both allow activity. `false` unsubscribes; the request commits
only after a successful callback. Availability is `available`, `permission-denied`,
`unsupported`, or `suspended` and can change during the session. Settings and
`pearlctl plugins list` report the current state and a source-level reason.

An `activity` event's `count = 1` means one coalesced notification, **not one key
press**. At most ten guest callbacks run per second; bursts merge and stale input
is dropped. No keys, text, button identities, device/window identity or input
timestamps reach plugins. Held-key repeats, releases, motion, scrolling, touch,
tablets and virtual devices do not count. Ordinary application password fields
are not detectable; suspension covers Pearl-managed authentication, compositor
locks and inactive native sessions.

Pearl uses one authorized subscription on GTK's existing Wayland connection and
acknowledges independently of guest speed. Local privacy gates stop helpers and
hide views before authentication. Pearl waits for the compositor's suspension
acknowledgment, with a bounded 500 ms fallback that destroys the subscription.
Fresh readiness is required on resume. Older compositors, unsupported sessions
and unauthorized launches retain local clicks and Settings Preview.

## CLI

```sh
pearlctl plugins list
pearlctl plugins list --offset 4
pearlctl plugins inspect --path pearl.timer-c
pearlctl preferences status                  # obtain current revision
pearlctl plugins enable --path pearl.timer-c --text PACKAGE_SHA256 --revision N
pearlctl plugins disable --path pearl.timer-c --revision N
pearlctl plugins reload --path pearl.timer-c
```

List/inspect include status, errors, fingerprint, capabilities and generation.
CLI changes reject stale preference revisions and retained Settings drafts.
Enabling a new fingerprint clears previously granted optional capabilities;
review and grant them in Settings. CLI reload is an explicit retry, not a package
rescan. These commands use the existing session-scoped Pearl control endpoint.

## Limits and trust boundary

- Maximum 32 discovered packages, 8 enabled instances; manifests 16 KiB and
  components 16 MiB. Discovery snapshot budget is 64 MiB including decoded images.
- One private socketpair and helper per instance. Messages are bounded to 64 KiB,
  ordered by generation and sequence, with one outstanding callback.
- Wasm memory: 32 MiB per memory, at most two memories; bounded tables/instances.
  Entire helper virtual address space: 512 MiB, including compilation. Native
  core dumps are disabled. Helpers die with their supervisor.
- Each callback gets one million fuel units and at most 64 host calls. Startup
  gets a 5-second deadline; subsequent callbacks get 100 ms. View events are
  limited to 10 per second; timers range from 100 ms to one day.
- Scenes have at most 32 nodes and four images. PNG assets, paths, dimensions,
  sprite rectangles, clip durations and settings are validated. Text is plain
  text, never GTK markup or executable CSS. Asset decoding runs off the GTK thread.
- No WASI imports, network, arbitrary filesystem, environment, process launch,
  raw devices, GTK pointers or system-service interfaces are exposed to guests.
  Snapshot fingerprints cover the manifest, component and every declared asset.
- A trap, timeout, malformed reply or changed package fails that instance and
  clears its views. Other plugins and native controls continue. Retry is explicit;
  there is no automatic crash loop. Revocation terminates the old generation.

The current scene model is deliberately flat: labels, buttons and images with
optional named clips. Future service APIs, richer layouts, live package rescans,
marketplaces and signatures require separate contracts. This is an opt-in
experimental implementation, not a completed third-party security audit.

## Verification

After building examples with `--fixtures`:

```sh
zig build test
zig build test-plugin-host -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
zig build test-plugins -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
# With the separate diagnostic Aqueous prefix; see the activity validation guide:
zig build test-plugin-activity -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/prefix
```

The [activity acceptance record](PLUGIN_INPUT_ACTIVITY_VALIDATION.md) records
the current unit, helper, compositor and private-session results. The Settings test clicks the actual enable switch
and Apply button; it also injects an invalid PNG while GTK warnings are fatal.

The helper suite exercises real C/Zig/Rust components, repeated calls, sprites,
traps, fuel exhaustion, host-call limits, invalid scenes, atomic publication,
rejected memory growth, package changes, symlinks and stale generations.
The desktop suite uses a private headless Aqueous session, isolated HOME and
mock system services. It checks native bar/overlay contributions, the main
Settings page, retained draft Apply, failure isolation, retry and inactive-session
cleanup/restart. These tests do not touch the user's desktop.

Physical hardware acceptance, broad scale/rotation coverage and the full
release soak/security/performance gates remain open in the
[original implementation plan](WASM_PLUGIN_IMPLEMENTATION_PLAN.md).
