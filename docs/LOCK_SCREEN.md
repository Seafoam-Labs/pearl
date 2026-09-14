# Native lock screen — T13

`pearl-lock` is Pearl's independent Zig 0.16 / GTK locker for Aqueous. T12
introduced the session-lock and PAM foundation; T13 completes the responsive
interface, accessible prompt handling, output lifecycle and dedicated failure
and resource checks. No external locker or additional C bridge is involved.

For installation, PAM policy, idle/sleep sequencing and recovery, start with
[SESSION_SECURITY.md](SESSION_SECURITY.md). `pearlctl lock` uses this executable;
only successful PAM authentication **and account validation** can unlock it.

## Interface and input

The screen follows Pearl's wallpaper and Material or installed GTK theme. Clock,
date and account card follow the configured text size. Compact lock layouts use
a smaller clock; very short outputs hide decorative content to prioritize the
authentication card. A scrollable viewport keeps keyboard focus visible when
large text or a long PAM message exceeds the available space.

- Enter submits the current response. After cancellation or failure, Enter
  retries once the cooldown ends. Tab/Shift+Tab retain GTK keyboard navigation.
- Escape cancels authentication and clears responses on every output. It never
  unlocks. GTK finishes the current key dispatch before focus is updated; a
  pending cancellation rejects authentication completion.
- Prompts switch between echoed text and hidden responses as PAM requests.
  Each entry's accessible label follows the actual prompt, and prompt/status
  changes request a screen-reader announcement. The Caps Lock indicator follows
  GDK keyboard state and announces changes.
- Entries use `GtkPasswordEntryBuffer` and private input hints. Spell checking,
  input learning and emoji suggestions are not requested. Responses remain
  read-only while PAM is processing, preserving GTK's focus-out delivery.
- Responses longer than **1023 UTF-8 bytes** are rejected and cleared, never
  silently truncated. Enter can then submit a new response. Empty-password
  authentication is disallowed through PAM flags.

GTK's secure entry buffer requests protected memory. This does not imply that
all copies inside GTK, an input method or PAM are scrubbed or cannot be swapped.
Pearl clears its own packet buffers and never logs prompt responses. There is
no password or unlock endpoint in `pearlctl`.

## Output and process ownership

The compositor's session-lock acknowledgement remains the security boundary.
New outputs are covered by a native lock surface or blanked by Aqueous while a
surface is being prepared. Monitor assignments are bounded, serialized and
coalesced over 100 ms. Invalid queued monitors are discarded, and references to
removed windows are released after monitor dispatch. Returned outputs receive
the current prompt and keyboard focus without copying another output's response.

This ordering matters with gtk4-layer-shell 1.3.0: assigning a window presents it
and can synchronously dispatch more Wayland monitor events. The T13 burst test
reproduced reentrant mapping and invalid-native focus diagnostics; queuing and
coalescing avoid those tested sequences. This is an application mitigation, not
an upstream library fix or a guarantee about every physical hotplug timing.
The relevant upstream implementation is
[gtk4-session-lock.c](https://github.com/wmww/gtk4-layer-shell/blob/v1.3.0/src/gtk4-session-lock.c).

The view and pending-output arrays each permit at most 64 entries. Exceeding
those bounds never requests unlock. Repeated reconnects reuse slots rather than
consuming that limit over the lifetime of the locker.

The internal `--ready-fd=3` descriptor must already be a writable pipe before
GTK initializes. This prevents an absent descriptor from later being mistaken
for GTK's Wayland socket. A closed reader cannot terminate an acquired locker.
Use `pearlctl lock` or plain `pearl-lock`; the readiness argument is for Pearl's
launcher, not normal interactive use.

Missing PAM policy, helper crash, malformed framing, account denial, timeout or
cancellation leave the compositor locked. A cancelled or timed-out helper is
killed and reaped. Retry starts a new helper. Shell exit and shell SIGKILL leave
the independent locker alive. Locker-crash recovery remains specific to the
pinned Aqueous behavior described in the session-security guide.

## Resource behavior

The clock runs at the next minute boundary. Clock updates do not restyle widgets,
reset focus or rewrite the authentication panel. Theme/output changes update
appearance; prompt changes update authentication controls; Caps Lock changes
update its indicator. The retry cooldown has a one-shot timer.

The dedicated suite records CPU ticks, RSS, PSS, descriptor counts and UI/clock
update counts. RSS includes shared library pages; PSS apportions them. The idle
sample describes the locker alone with authentication cancelled, not the entire
desktop or a running PAM module. Output reconnect samples record retained memory
separately. These bounded measurements are not a claim of zero allocation or
an indefinite leak-free soak.

## Verification

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
zig build test-lock -Doptimize=ReleaseSafe
zig build test-security -Doptimize=ReleaseSafe -- --output artifacts/t13/regression/security
# Optional longer private run:
zig build test-lock -Doptimize=ReleaseSafe -- --hotplug-cycles 1000 --idle-seconds 600 --output .cache/lock-soak
```

`test-lock` uses a private Aqueous display, GTK's accessibility test backend and
a private Linux-PAM module. Its defaults exercise 100 settled output reconnects,
a burst of 12 reconnects, all-output removal/return and a 65-second idle sample.
The test build checks actual GTK accessible labels and secure buffer types;
keyboard input drives real entries. No test endpoint can submit a password or
unlock a production locker. The shortened PAM timeout exists only in the
non-installed instrumented binary.

[T13 evidence](../artifacts/t13/README.md) includes screenshots and measurements.
Physical acceptance still requires an installed production PAM policy, actual
mixed-DPI hardware, DPMS/lid/suspend/resume and a real screen reader. The private
GTK accessibility backend does not verify Orca speech or a session's AT-SPI
permissions. Fingerprint/smart-card and expired-password policies depend on the
installed PAM stack; expired account/password-change requirements remain denied
unless account validation succeeds. No host PAM policy or user unit was changed
while implementing T13.

On a dedicated physical Aqueous login with a working installed PAM policy:

| Action | Expected result |
| --- | --- |
| Enable the session's screen reader, then run `pearlctl lock` | Account, current prompt and controls are discoverable; hidden responses are not spoken as plaintext |
| Use Tab/Shift+Tab, Caps Lock, Escape and Enter | Focus stays visible; Caps Lock/status changes are announced; cancellation stays locked and Enter retries |
| Lock with differing scales/rotation, then unplug and reconnect displays during a prompt | Each output is covered or blanked; returned outputs accept the current prompt |
| Exercise actual DPMS, lid close and suspend/resume | Outputs return locked with usable keyboard focus; no stale response is submitted |
| Check the installed password, account-expiry and any fingerprint/smart-card policy | PAM decisions are respected; denied or unsupported account requirements cannot unlock |

The session-security guide contains the confirmed suspend and service-restart
commands. Record compositor/library versions, output scales and authentication
policy with physical results; do not substitute fixture success for these checks.
