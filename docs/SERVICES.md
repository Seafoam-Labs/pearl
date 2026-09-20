# Audio, power and OSD (T07)

Pearl now connects to PulseAudio or PipeWire's PulseAudio-compatible service,
UPower, logind and optional power-profiles-daemon. The control center has live
sound controls, battery state, brightness, profiles and deliberate power actions.
The bar's `audio` and `battery` groups open the compact Sound and Power & battery
pages respectively; both are in the
default right group, and battery hides when no battery is reported. Missing
services leave the shell and its panels usable.

## Audio

`src/services/audio.zig` integrates libpulse with GTK's default GLib context via
`pa_glib_mainloop`. [Pinned headers](../bindings/headers/README.md) generate its
Zig ABI during the build. There is no `pactl` subprocess or C bridge in Pearl.

The adapter subscribes to server, sink, source, playback-stream and recording-
stream changes. It reads server defaults and bounded lists into a staging
snapshot, then publishes the complete snapshot. It holds at most 128 entries;
status reports truncation. Devices/streams retain kind, index, connection
generation, names, channel volumes, mute and routing. Labels/names are bounded
to 256 UTF-8 bytes; oversized device names are excluded from action targets.
A 35 ms source coalesces refreshes and writes; each enumeration stage/write has
a five-second deadline. One introspection/write operation is outstanding, plus
the initial subscription acknowledgement.

Control-center sound rows expose output/input defaults, volume and mute for
both devices and applications. Stream rows can move to the current default;
the CLI can select another compatible device explicitly. The Sound expander
keeps these detail controls together in Sound's own scrollable body. Read-only
stream volume controls are disabled. No-device and disconnected states replace
the rows without leaving callbacks attached to freed models.

Volume controls cover 0–100%, without amplification above nominal volume. The
slider uses the highest channel volume; proportional scaling preserves channel
balance, and silent devices initialize channels uniformly. Mute is independent.
Rapid mute toggles consult pending intent, rather than repeatedly toggling the
same old observed state.

Writes carry a connection generation and captured device/stream index. A queue
holds at most 32 distinct targets, merges the latest volume/mute/default/routing
intent per target, and dispatches one operation at a time. Updates received
while a write is in flight remain queued and preserve the final intended value.
Changing the default does not redirect a queued drag to a different device.
Disappearance rejects that target; reconnect increments the generation and drops
old pending mutations. Disconnected audio retries with exponential backoff from
one to 30 seconds, without auto-spawning a daemon. Successful reconnection resets
the backoff. Initial absence updates availability without repeatedly showing OSD.

A libpulse success callback is followed by authoritative enumeration. Service
errors remain visible; local accepted changes produce OSD feedback after the
refreshed snapshot is published. Changes to the default output's displayed
volume or mute state show a volume card, including changes made by external
clients and existing media-key bindings. Complete snapshots are compared by
connection generation and device identity: startup, reconnection, default-device
switches, and unchanged subscription events establish or retain a silent baseline.
External changes to other devices and application streams only update rows/bar.
Explicit Pearl changes to those targets retain text feedback.

## Battery, logind and profiles

`src/services/power.zig` uses Ghostty's asynchronous GIO D-Bus bindings on the
system bus. Proxies watch cached properties and unique-owner changes. UPower's
DisplayDevice provides aggregate battery presence, percentage, charging state
and estimated times; the root object provides on-battery state.

logind's `CanPowerOff`/`CanReboot` replies determine availability. They are queried
on owner acquisition and panel opening, with at most one pending query each.
`GetSessionByPID` identifies Pearl's session; its `Active` property gates
brightness. PrepareForSleep/PrepareForShutdown invalidate relevant availability.
T12 now implements suspend/hibernate and native lock/inhibitor orchestration;
see [SESSION_SECURITY.md](SESSION_SECURITY.md). Pearl waits for verified lock
acquisition before requesting suspend.

Power off and restart require **two activations of the same button within ten
seconds**. Cancel, popup closure, expiration or a service generation change
invalidates confirmation. The second activation sends one asynchronous logind
request with interactive authorization disabled. Only a `yes` capability is
enabled; `challenge`, `no`, missing service and pending/preparing states do not
silently escalate permission. Denial or unconfirmed replies are visible. An
accepted reply is reported as service acceptance, not proof of eventual machine
shutdown. No power-off/restart command is exposed through the CLI in this slice.

Profiles support the modern `org.freedesktop.UPower.PowerProfiles` service and
legacy `net.hadess.PowerProfiles`, preferring modern when present. Only advertised
power-saver/balanced/performance choices are enabled. ActiveProfile and optional
PerformanceDegraded remain authoritative. Profile writes coalesce to a single
latest desired value while one call is outstanding. A rejected brightness write
does not discard an independent queued profile change.

D-Bus mutations target the captured **unique owner**, with expected reply types,
three-second deadlines and generation checks. A new daemon cannot receive an
old mutation. Proxy construction also has generation checks. Owner/bus loss
clears pending intent; bus recovery retries after five seconds and does not exit
the application. Cancellation plus application holds drains outstanding async
callbacks before service storage is released. No service is auto-started.

## Validated brightness

A cancellable GTask reads `/sys/class/backlight`; GTK never scans files on its
main thread. The scan considers at most 64 entries, validates device-name
components, positive 32-bit maximums and current values within range. It keeps
an existing valid selection; otherwise it selects the first valid name in
lexical order. Multiple-display DDC and a backlight chooser are future work.

The only write path is logind Session.SetBrightness with the literal subsystem
`backlight`, the validated name and a bounded value. Pearl never writes sysfs or
executes a privileged helper. Zero slider position maps to the smallest nonzero
hardware value to keep the panel lit. Permission denial retains observed state.
A 40 ms source coalesces writes; a queued update survives an in-flight reply and
is read back after success. Device removal drops pending intent for that device.

Directory monitoring discovers additions/removals. While a Power page owner has
live interest and a backlight exists, a two-second worker refresh observes changes because
sysfs brightness attributes do not reliably emit ordinary file-monitor events.
The poll stops after the last Power owner leaves. There is one scan worker, one coalesced rescan and
one brightness write at a time. No backlight means an explicit unavailable state.
Only the instrumented integration executable accepts the private fixture root;
the production binary always uses `/sys/class/backlight`.

Open these pages with `pearlctl control-center show --page sound` or `--page power`.
Overview and the section chooser retain access when an icon is omitted or no
battery is present. Page-local navigation and
[owner-scoped interest](SETTINGS_SERVICE_OWNERSHIP.md) do not duplicate service policy.

## CLI and OSD

```sh
pearlctl services status                    # four audio entries per page
pearlctl services status --offset 4
pearlctl audio set --kind sink --volume 45  # capture the current default output
pearlctl audio set --kind source --mute true
pearlctl audio set --kind sink --generation GENERATION --device INDEX --default true
pearlctl audio set --kind playback --generation GENERATION --device INDEX --target SINK_INDEX
pearlctl brightness set --percent 65
pearlctl profile set --profile balanced
pearlctl bar groups --output OUTPUT_ID --left launcher,workspaces,title \
  --center clock --right audio,battery,keyboard,overview,control
```

These are additions to the existing same-UID/session/display validated control
v1 endpoint. `audio_set`, `brightness_set` and `profile_set` return `queued:true`.
The CLI checks applicability, identity pairs and numeric ranges before sending.
Requests with explicit audio IDs require their generation; playback/recording
always require explicit identity. Mutations are unavailable in a locked or
unavailable Aqueous session. Rejected values use InvalidRequest/InvalidValue;
missing devices use Unavailable, a full queue uses Busy, and daemon reply errors
appear in service status and the affected panel/OSD.

`pearlctl status` includes a service summary. `services status` includes audio
pages of four entries with 64-byte name/96-byte label previews, generation,
next_offset, defaults, observed volume/mute/routing, availability, pending and
in-flight state. Power status includes battery, profile, session/preparation,
capabilities and errors; brightness includes device/range/readback state. Pages
are current snapshots, not a transaction across multiple queries; consumers must
revalidate identity/generation when acting.

OSD keeps **one surface, one pending payload and one expiry source**. Text and
volume content reuse that surface. The volume card shows a speaker/mute icon,
ellipsized device name, percentage, and level meter. Muting retains the stored
percentage with a subdued meter; zero volume without mute displays `0%`.
Service feedback coalesces for 80 ms and expires 1,800 ms after its latest
displayed update. Unchanged observations do not extend expiry. A newer direct
OSD request cancels older queued feedback.

Service bursts stay on their initially selected display. Cards are centered at
the bottom with 24 logical pixels of clearance above Pearl's bottom reservation.
Output changes replace the surface; removal discards pending feedback.
`status.osd_text` remains a readable summary. Additive `status.osd_detail` reports
the content kind, display, and (for volume) device key/name, percent, and mute.
Existing layer-shell keyboard mode/input-region policies keep it non-focusable
and click-through. Lock, inactive session, and compositor loss dismiss and discard
feedback. OSD never queues an unbounded history or replays across lock/loss.

## Validation and physical release checklist

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
zig build test-services -Doptimize=ReleaseSafe
zig build test-desktop -Doptimize=ReleaseSafe -- --output artifacts/t07/desktop
zig build test-surfaces -Doptimize=ReleaseSafe -- --output artifacts/t07/surfaces
zig build integration -Doptimize=ReleaseSafe -- --output artifacts/t07/lifecycle
python3 scripts/check-pulse-bindings.py
```

The service suite uses separate private session/system buses, a private Aqueous
compositor, a minimal PipeWire/Pulse server with synthetic sinks and real pacat
playback/recording clients, and a delayed/denied Python GIO power peer. Its minimal
fixture policy publishes effective PipeWire defaults independently of configured
defaults; no hardware/session-manager monitor is loaded. All brightness files
and accepted/denied reboot calls belong to that fake peer. The ordinary private
session helper also pins PULSE_SERVER to its private runtime to prevent fallback
to host audio. Test power controls must never be repointed at a host bus.

[Service results](../artifacts/t07/latest/results.json),
[visual evidence](../artifacts/t07/comparison.html) and
[verification records](../artifacts/t07/verification/README.md) record the final
checks. The instrumented build has read-only GTK focus probes for real keyboard
confirmation tests. Production has no fixture-root or focus-probe behavior.

Physical release checks are deliberate manual work, **not CI side effects**:

- On supported laptop hardware, verify backlight range/readback, low end,
  permissions, active/inactive sessions and hotplug/resume. This development
  desktop has no `/sys/class/backlight` devices, so physical validation remains open.
- Verify battery/AC transitions, time estimates and profile availability/degraded
  reasons on real power hardware; test any installed authorization agent separately.
- On an explicitly selected disposable session/machine, verify cancel, deny and
  accepted power-off/reboot behavior, including inhibitors and multiple sessions.
- Verify physical audio devices, microphone privacy indicators, balance,
  Bluetooth/USB removal, server restart and device-default changes during a drag.
- Complete screen-reader/large-text review, long-duration memory/idle/refresh-rate
  budgets and the release soak. T07 does not claim these release gates complete.

The authoritative API references are the vendored Pulse headers, local systemd
login1 introspection XML, [UPower Device documentation](https://upower.freedesktop.org/docs/Device.html)
and [power-profiles-daemon interface](https://upower.pages.freedesktop.org/power-profiles-daemon/gdbus-org.freedesktop.UPower.PowerProfiles.html).
