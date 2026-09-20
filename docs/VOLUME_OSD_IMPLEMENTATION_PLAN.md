# Volume on-screen display implementation plan

Status: implemented and verified in isolated sessions on September 20, 2026.
The unit, service, and surface suites pass. See
[verification results and screenshots](../artifacts/volume-osd/README.md).

Delivered: complete-snapshot change detection, a themed volume/mute card,
text/card surface reuse, bounded coalescing/expiry, additive diagnostic status,
and session/device/display invalidation. Native lock and click-through tests,
long labels at 150% scale, and dark/light/GTK-theme captures are included.
Layer-shell's existing zero exclusive zone handles reservations; adding the bar
height to its margin would count that space twice. The implementation uses a
24-pixel margin within the compositor's usable area and clamps preferred width
to that area's width.

## Goal and scope

Show a compact volume indicator whenever the default audio output's observed
volume or mute state changes, including changes made through Pearl, media-key
bindings, and external audio tools. Media-key bindings must already change the
audio service; this feature observes their result and does not install bindings.

Keep existing feedback for explicit Pearl changes to other audio devices and
application streams. External changes to those targets remain quiet. Microphone
OSD redesign, brightness redesign, new volume shortcuts, amplification above
100%, and configurable OSD placement are separate work.

## Starting point before implementation

- `src/services/audio.zig` subscribes to audio changes and publishes complete
  snapshots. Its `.applied` event supplies feedback after a successful local
  write and subsequent enumeration; external changes produce `.state` events.
- `src/ui/surfaces/manager.zig` currently turns local audio feedback into text.
  Service feedback coalesces for 80 ms and remains visible for 1,800 ms.
- The existing OSD is a bottom-centered overlay, 24 logical pixels from the
  bottom, with a nominal size of 320 × 72. It is click-through and never takes
  keyboard focus. Repeated updates reuse its surface and reset its expiry.
- `docs/SERVICES.md` currently documents intentionally silent external changes.
  This plan changes that behavior only for default-output volume and mute.

## User experience

Use a rounded card approximately 320 logical pixels wide, sized vertically to
its content. Show a speaker icon, output-device label, percentage, and horizontal
level meter. Ellipsize long device labels. Reuse Pearl's theme colors, typography,
corner treatment, and blur/opaque fallback.

| State or event | Display behavior |
| --- | --- |
| Volume changes | Show the confirmed percentage and meter level. |
| Mute enabled | Show a muted icon and “Muted”; retain the stored percentage with a subdued meter. |
| Zero volume without mute | Show “0%” with an empty meter; do not label it muted. |
| Mute disabled | Restore the speaker icon and normal meter at the stored volume. |
| Repeated changes | Update the same card and expire 1,800 ms after the latest displayed update. |
| Startup, reconnect, or default-output change | Establish a fresh baseline without showing a volume popup. Dismiss a volume card for the previous output device. |
| Unrelated subscription event or unchanged displayed state | Do not show the card or extend its timeout. |
| Lock or compositor loss | Dismiss and discard pending feedback; do not replay on recovery. |

Keep bottom-center placement, with at least 24 logical pixels of clearance from
Pearl's bottom bar/frame reservations. Clamp width and placement on small outputs.
Use the existing unique-seat output-selection policy; when no unambiguous eligible
output exists, drop feedback. Keep an active burst on its selected display until
expiry; display removal dismisses it. Never duplicate the card across monitors.

The meter is informational, not an interactive slider. Provide localized text
and accessible names, and communicate mute with text/icon as well as color.
Initial delivery uses immediate updates without animation.

## Implementation stages

### 1. Define and test volume-change policy

Add a small pure policy module, such as `src/services/audio_feedback.zig`, that
compares completed snapshots of the default sink. Track connection generation,
device identity (including name), displayed percentage, and mute state.

Compare snapshots at publication in `Audio.next`, before overwriting the old
snapshot, or expose an equivalent explicit completed-snapshot callback. Do not
infer external changes from every `.state` callback: request queuing also emits
that event. The initial complete snapshot, a new generation, missing device, or
changed default identity resets the baseline. Emit at most one volume update for
a changed displayed percentage/mute pair on the same default device.

Use this single observed-change path for both local and external changes to the
default sink. Suppress its duplicate generic `.applied` feedback for volume/mute
writes. Retain operation metadata so default selection, routing, non-default
device changes, and stream changes keep appropriate existing feedback. A failed
write must never produce a successful volume card.

Continue advancing the baseline while feedback is suppressed by lock; reset it
when observations become unavailable. Unlock/recovery must not replay changes.

### 2. Introduce structured OSD content

Add an internal bounded payload with `text` and `volume` variants. Volume carries
copied device identity/label, percentage, and mute state; it must not retain
pointers into replaceable audio snapshots. Keep the public `pearlctl osd show
--text` interface compatible.

Refactor the manager's queue and presentation path to consume this payload.
Retain one surface, one pending payload, one coalescing source, and one expiry
source. Latest feedback replaces earlier pending feedback; direct text requests
cancel older pending service feedback. Changing content type reuses the surface
and replaces its child content cleanly. Clear both timers and payload on lock,
output loss, shutdown, and other existing invalidation paths.

Keep `status.osd_text` as a readable summary for compatibility. Add optional
structured OSD status containing kind, target display, audio-device identity,
percentage, and mute state to support precise diagnostics and integration tests.

### 3. Build and integrate the volume card

Extract a reusable widget into `src/ui/surfaces/osd.zig` and connect it from
`manager.zig`. Use a GTK level/progress widget, a symbolic speaker/mute icon,
device label, and numeric/status text. Add missing icons through the established
bundled icon system. Add styles to both `resources/style.css` and
`resources/gtk-theme.css`, respecting existing theme scopes.

Update the card in place during bursts. Route default-sink observed changes into
the structured queue; retain generic service errors and other text feedback.
Calculate placement using existing output geometry/reservations, and revalidate
the target device and display before flushing queued content.

### 4. Verify behavior and document the change

- Pure policy tests: initial snapshots, repeated identical snapshots, local and
  external deltas, mute at unchanged volume, zero volume, default switching,
  device disappearance/index reuse, reconnect, and suppression/recovery.
- Extend `tests/integration/test_services.py` using its private Pulse-compatible
  server: external `pactl` changes show the card; local writes show one update;
  unrelated streams stay quiet; rapid changes converge to the final observed
  state; expiry follows the final update; failed writes retain error feedback.
- Extend surface coverage for text/volume replacement, focus preservation,
  click-through behavior, lock with pending feedback, output removal, and
  unambiguous selection across multiple displays.
- Capture light/dark and GTK-theme screenshots, mute/zero/full states, long
  labels, fractional scale, and a bottom bar. Confirm readable contrast and no
  clipping or reservation overlap.
- Run the affected existing unit, service, and surface suites in isolated
  sessions. Do not change host volume during automated verification.
- Update `docs/SERVICES.md` and `docs/SURFACES.md` with the trigger policy,
  appearance, lifecycle, and additive diagnostic fields.

## Completion criteria

A real default-output volume or mute change produces one accurate, themed card
on the selected display, regardless of which client changed it. Repeated changes
reuse the card and leave the final observed value visible before expiry. Startup,
reconnect, unrelated audio activity, and unlock do not cause surprise popups.
Existing text OSD commands, service feedback, focus, and pointer behavior remain
compatible, with automated coverage and screenshots recorded.
