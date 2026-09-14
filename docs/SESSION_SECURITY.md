# Session security, idle and native lock

T12 provides session actions, idle/sleep coordination and a real polkit agent.
Per the user's clarification, it also brings forward T13's native locker:
**Pearl does not launch swaylock or another external locker.** `pearl-lock` is a
separate Zig/GTK executable with a Noctalia-like clock, date, account card and
unlock conversation. It follows Pearl's Material or installed GTK theme and
wallpaper. The shell and locker have separate lifetimes.
[T13 native lock details](LOCK_SCREEN.md) cover responsive layout, accessibility,
output churn, protected entry buffers and dedicated resource/failure tests.

The implementation uses Zig 0.16.0, Ghostty's shared GTK/GIO types, generated
Polkit/PolkitAgent GIR namespaces, generated ext-idle-notify declarations and
translated pinned Linux-PAM headers. No custom C bridge is used. Current pins
are GTK 4.22.5, gtk4-layer-shell 1.3.0 and polkit 127.

## Controls and configuration

Open **Control center → Session & security** for Lock, Suspend, Hibernate, Log out
and pause/resume automatic idle. Logout/suspend/hibernate require a confirmation
that expires after 20 seconds. Power off/restart retain T07's confirmation UI.
The CLI has the same confirmation boundary:

```sh
pearlctl lock
pearlctl lifecycle status
pearlctl lifecycle action --text suspend
# Read the pending action and confirmation generation from lifecycle status.
pearlctl lifecycle action --text confirm --generation NUMBER
pearlctl lifecycle action --text cancel
pearlctl lifecycle action --text inhibit
pearlctl lifecycle action --text uninhibit
```

`inhibit` pauses **Pearl's** automatic idle policy until resumed or Pearl exits;
it is not a global inhibitor for other programs. Locking manually remains
available. `lifecycle status` exposes availability, active logind session,
authentication-agent registration, lock acquisition, current policy, inhibitor
ownership and failures. It never exposes credentials, authentication cookies or
prompt responses. An accepted lock request is not reported as acquisition.

Configure **Pearl settings → Session**, or the `idle` object in
`$XDG_CONFIG_HOME/pearl/preferences.json`:

```json
{
  "version": 1,
  "idle": {
    "ac": { "lock_seconds": 600, "suspend_seconds": 1800 },
    "battery": { "lock_seconds": 300, "suspend_seconds": 900 }
  }
}
```

This is a minimal file example; preserve other preferences when editing an
existing file. Zero disables that automatic timeout. All automatic timeouts
are zero by default; configuring idle is an explicit opt-in. Suspend must have
a preceding nonzero lock timeout, and each timeout is bounded to 24 hours.
AC/battery changes rearm the relevant compositor notifications. UPower supplies
the power-source state; unavailable UPower retains the power service's AC
fallback. Manual actions still require current service capabilities.

Idle uses ext-idle-notify's inhibitor-respecting notifications. It does not
synthesize mouse activity or infer inactivity from a timer. Ambiguous multiple
seats disable automatic idle until there is one unambiguous supported seat.
Before idle actions Pearl checks logind's block inhibitors; before its own
suspend it checks again after acquiring the lock. An inactive/missing logind
session, unavailable compositor, sleep inhibitor, missing delay inhibitor or
unconfirmed lock prevents Pearl from requesting suspend.

## Native lock and PAM

`pearl-lock` owns real session-lock surfaces on every output using
`gtk4-session-lock`; an ordinary fullscreen overlay is never considered a lock.
Monitor removal/return is handled through GTK monitor validity and the binding's
monitor signal. Aqueous can blank an output during lock acquisition; only the
protocol's `locked` acknowledgement is the success boundary.

When started by Pearl, the locker receives an anonymous readiness descriptor.
It emits one byte **only after `locked`**. Pearl requires that acknowledgement
and the current Aqueous locked state before continuing suspend. It waits at most
8 seconds for acquisition. A missing, malformed, false or late readiness signal
cannot authorize suspend. The readiness channel is not an unlock endpoint.

Authentication runs in a separate `pearl-lock --pam` subprocess using the current
UID and the fixed `pearl` PAM service. The helper handles bounded multi-message
conversations, echoed/hidden prompts, informational/error messages and account
policy. Both `pam_authenticate` and `pam_acct_mgmt` must succeed before unlocking.
Expired-account/password-change requirements therefore fail closed rather than
skipping account policy. The locker does not open a new PAM login session.

The helper uses private binary pipes, not passwords in argv/environment or shell
commands. Responses are bounded, temporary owned buffers are cleared, core dumps
are disabled, and authentication data is omitted from diagnostics. GTK and PAM
may maintain their own internal copies; buffer clearing is not a claim that all
library memory is scrubbed. Escape cancels the conversation, clears entries and
leaves the session locked. Enter retries after cancellation or failure. An attempt has a 90-second deadline; failure permits
a retry after a short cooldown. A hung/crashed authentication helper cannot
unlock the screen.

Closing Pearl or restarting its service leaves the native locker alive. Killing
the locker leaves the pinned Aqueous compositor locked. Aqueous revision
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480` permits a new lock client to take over an
abandoned lock; the private suite verifies re-acquisition and authenticated
unlock. This is a tested Aqueous behavior, not a portable Wayland guarantee.
On that version, launch `pearl-lock` from the same session environment to recover
an abandoned locker. Do not restart the compositor as a way to claim secure
unlock. A compositor/session restart has a different security boundary.

## Suspend, resume and logout

Pearl registers a logind `sleep` **delay** inhibitor while the session is
available. For a Pearl-initiated suspend/hibernate it first acquires the native
lock, confirms Aqueous state, rechecks inhibitors and requests the action.
`PrepareForSleep(true)` releases the delay descriptor only when acquisition is
confirmed. Resume (`false`) reacquires the delay inhibitor and rearms idle;
resume never unlocks the screen.

A delay inhibitor cannot veto an externally initiated sleep indefinitely:
logind may proceed after its configured maximum delay even if locking fails.
On that failure Pearl retains the descriptor, reports the failure and never
claims that the screen locked. **No automatic suspend initiated by Pearl proceeds
on that failed acknowledgement.** External forced sleep/lid policy must be
validated on the actual installation. Capability checks or suspend calls that
need authorization may fail while the session is locked; Pearl does not display
an authentication prompt over a lock screen or bypass authority policy.

Logout drains Pearl’s services and GTK application, then closes its Wayland
connection before sending `session.exit` through the existing verified Aqueous
IPC connection. A separate GLib loop waits for the bounded command result; the
process reports failure if the compositor cannot acknowledge the request. Under UWSM, compositor exit drives UWSM's session shutdown. Pearl
does not stop an arbitrary systemd user session or run `uwsm stop` against an
unverified session. The supplied user unit is tied to `graphical-session.target`
and requires the exported Wayland/Aqueous environment.

## Polkit agent

Pearl registers `org.freedesktop.PolicyKit1.AuthenticationAgent` for the logind
session resolved from its own PID. Calls are accepted only from the current
unique owner of the polkit authority name. Existing agent ownership is not
forcibly replaced. Authority loss/restart cancels outstanding authentication,
invalidates registration and re-registers against the new owner.

The GTK authentication panel shows the action, message and offered identities.
It handles up to eight concrete Unix-user identities, lets the user select one,
and cancels the old conversation when the selection changes. Non-user identities,
malformed requests, duplicate identities and excessive requests are explicitly
rejected. A second simultaneous request is rejected rather than queued behind
an unseen prompt. PAM authentication of a selected identity uses the real
`PolkitAgentSession` and its trusted system helper; Pearl never forwards passwords
to an arbitrary executable or grants privileges itself.

Cancel, Escape, close, authority loss, session inactivity, lock acquisition and
the 120-second request deadline complete the outstanding D-Bus request and clean
up conversation/UI state. The authority receives authorization proof through its
trusted helper; completion of the UI request alone grants no permission.

## Build, stage and run

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
DESTDIR=/tmp/pearl-package-stage packaging/install.sh
```

The staging installer includes `pearl`, `pearlctl`, `pearl-lock`, a user service
and a PAM policy. It does not enable a unit or change the current session.
The supplied PAM file includes `system-auth` for the Arch-style environment;
distributions must adapt it to their established authentication/account stack.
Review the staged package before deploying. **Install a working PAM policy
before using the production locker.** Missing/invalid policy prevents unlock;
there is no password bypass or permissive fallback.

The user service uses `KillMode=process` so restarting Pearl cannot kill its
independent locker. Do not change it to `control-group` without first placing
the locker in its own independent service. Let Aqueous/UWSM export the session
environment before starting Pearl. Enable one polkit agent and one idle manager
for the session; Pearl reports a registration conflict with an existing agent.

## Verification and remaining acceptance

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-security -Doptimize=ReleaseSafe
python3 scripts/generate-bindings.py --check
python3 scripts/check-wayland-bindings.py
python3 scripts/check-pam-bindings.py
```

The security suite runs a real headless Aqueous display, private session/system
buses, a login1/polkit authority fixture, native GTK lock surfaces and Linux-PAM
with a private test module. Only the non-installed `pearl-lock-test` build accepts
a private PAM directory. Production rejects those test overrides. No host PAM
configuration, password, display, service ownership or sleep state is changed.
Screenshots and results are recorded under `artifacts/t12/`.

Physical acceptance remains required. On a disposable Aqueous session with a
working production PAM stack, perform these checks deliberately:

| Command/action | Expected outcome |
| --- | --- |
| `pearlctl lock`; wrong password, Escape, then correct password | Wrong/cancelled authentication remains locked; correct PAM authentication and account policy unlock |
| Lock with mixed-scale/rotated monitors; unplug/replug one | Every connected output remains covered or compositor-blanked, with usable unlock input |
| `systemctl --user restart pearl.service` while locked | Lock stays intact and the same locker can authenticate |
| `pkexec /usr/bin/true` in an unlocked session | Pearl shows the real polkit conversation if authorization is required; Cancel denies it; success follows the installed authority policy |
| `pearlctl lifecycle action --text suspend`, inspect status, then confirm its generation | Native lock acquisition precedes actual sleep; resume stays locked |
| `systemd-inhibit --what=idle:sleep --mode=block sleep 60` | Automatic idle/sleep respects the block; the unrelated command has no access to credentials |
| Configure short AC/battery delays in Pearl settings; connect/disconnect power | Appropriate idle policy is rearmed; no automatic suspend follows failed locking |
| Lid close/external sleep and resume, with and without active inhibitors | Validate actual logind delay limit, lid policy, hardware wake and lock coverage |
| Confirm Log out in a dedicated UWSM session | Compositor/session stop; Pearl's services disappear; no duplicate/restarted shell remains |

T13 implements responsive input, GTK accessibility labels/announcements and
bounded resource verification. Hardware, actual screen-reader, PAM-distribution,
fingerprint/smart-card and broader long-run acceptance still need installation
validation. No image-by-image Noctalia visual parity is
claimed. The UI follows its integrated clock/account/conversation approach while
using Pearl's existing theme and Aqueous-only protocols.

References: [Noctalia's integrated shell](https://github.com/noctalia-dev/noctalia),
[GTK session-lock API](https://wmww.github.io/gtk4-layer-shell/gtk4-layer-shell-GTK4-Session-Lock.html),
[polkit authentication agents](https://polkit.pages.freedesktop.org/polkit/polkit-agents.html),
[PolkitAgentSession](https://polkit.pages.freedesktop.org/polkit/PolkitAgentSession.html),
[logind inhibitor semantics](https://github.com/systemd/systemd/blob/main/docs/INHIBITOR_LOCKS.md).
