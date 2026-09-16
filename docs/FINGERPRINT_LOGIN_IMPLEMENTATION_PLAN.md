# Fingerprint login implementation plan

> Hosting update: ordinary Aqueous is now the supported pre-login compositor.
> References below to requiring a restricted Aqueous mode are historical and
> superseded by [the current host contract](AQUEOUS_GREETER_REQUIREMENTS.md).
> Real greetd/PAM and desktop handoff acceptance remains required.

Status: **Pearl implementation and private validation available; real-device/login acceptance remains gated**.
No host PAM, enrollment, reader ownership or display-manager configuration was changed.
See [usage and policy documentation](FINGERPRINT_LOGIN.md) and
[candidate evidence](../artifacts/fingerprint/latest/README.md).
Prepared September 14, 2026 against Pearl
`1530c6b7aecbdc2cab8b43983b372816ce7b672a`, using Zig **0.16.0**.

This extends the [greeter plan](GREETER_IMPLEMENTATION_PLAN.md). It defines a
first release of fingerprint login for pre-enrolled accounts, with password
fallback, concrete implementation tasks and separate hardware acceptance.
The greeter's existing restricted-Aqueous and real-login gates still apply.

## Scope and decisions

| Area | Required behavior |
| --- | --- |
| Login | Authenticate the selected account through greetd and the administrator's PAM policy |
| Fingerprint backend | `pam_fprintd` → fprintd → libfprint/supported reader |
| Password fallback | A finite fingerprint phase followed by the distribution's password flow when fingerprint authentication is unavailable or unsuccessful |
| Desktop support | Preserve selection and launch behavior for Pearl/Aqueous and all supported installed Wayland/X11 desktops |
| Locker | Validate the existing `pearl-lock` PAM path with the same kind of conversation; retain separate login/unlock authority |
| Presentation | Existing Material/GTK styling, accessible status, one greeter prompt owner, no Enter requirement for informational scan messages |
| Policy ownership | Distribution/administrator configuration; Pearl does not install a universal PAM stack or enable fingerprints through a UI preference |
| Enrollment | Use existing authenticated fprintd enrollment tooling; enrollment/removal UI is a separate future feature |

Fingerprint login is an optional alternative under the chosen PAM policy, not a
requirement to add another factor to every password login. Sites that require
multiple factors keep that policy: Pearl must continue presenting subsequent
questions and must never treat a fingerprint match as completion of the stack.

First release excludes simultaneous password/fingerprint races, a pre-login
enrollment editor, custom fingerprint drivers, biometric-template storage,
fingerprint-based account discovery, and changes to sudo/polkit authentication.
Unlocking another desktop after login remains that desktop's responsibility.

## Baseline facts and the original implementation gap

- At planning time, installed packages are greetd **0.10.3-2.1**, Linux-PAM
  **1.7.2-2.1**, and Zig **0.16.0-1.1**. Neither fprintd nor libfprint is installed.
  No reader/enrollment compatibility has been established. FP00 must pin the
  actual test packages and device; do not infer support from a laptop model.
- `src/greeter/protocol.zig` and `controller.zig` already support visible,
  secret, info and error conversation messages. At the starting revision, `screen.zig` made
  informational messages wait for a user-submitted null answer. That can hold
  a fingerprint instruction at a Continue button instead of progressing the
  daemon conversation. The old UI test explicitly pressed Enter for info; FP02/FP03
  replace this with automatic acknowledgement while retaining the instructions.
- `src/lock/pam.zig` already forwards PAM info/error messages without waiting for
  an input response; its final result includes `pam_acct_mgmt`. The locker has
  a separate fixed service, `pearl`, and a 90-second helper deadline. It must
  not acquire greetd's login responsibilities or copy its acknowledgement logic.
- The inspected greetd source is tag 0.10.3, commit
  `08efe60feceea8c81f9571c666880ff1e1c2e3ff`. Its ordinary create request chooses
  a username, not a PAM service or authentication method. It has no typed
  fingerprint-status field. Source and cancellation findings are recorded in
  [GREETER_COMPATIBILITY.md](GREETER_COMPATIBILITY.md); FP00 must match installed
  distribution patches before real authentication acceptance.

`pam_fprintd` verifies previously enrolled fingerprints. Its documented PAM
conversation is serialized: a single stack cannot offer password and fingerprint
authentication concurrently. It supplies finite timeout/retry options; infinite
values must not be used in this release's example profile. These facts determine
the sequential fallback design. [Upstream pam_fprintd manual, distributed by Arch](https://man.archlinux.org/man/pam_fprintd.8.en)

fprintd exposes device claiming, verification and enrollment over D-Bus, with
PolicyKit authorization for access, including other users' data. This plan keeps
those operations behind PAM; the greeter does not claim the reader or query
enrollment for a typed username. [fprintd Device API](https://fprint.freedesktop.org/fprintd-dev/Device.html)

The upstream device list describes the development version of libfprint, so an
entry there is not proof of support in the installed release. Record the actual
USB/SPI device, driver and package used for acceptance. [libfprint supported devices](https://fprint.freedesktop.org/supported-devices.html)

## User flow

1. Select an account and desktop, then activate Sign in. Freeze both choices for
   the attempt, as the greeter does today.
2. Present the daemon's actual scan instruction or other status. The password
   entry appears only for a secret/visible input question. No Continue press is
   required merely to acknowledge an info/error conversation message.
3. Keep the latest instruction visible while the daemon is processing. A reader
   retry message replaces or supplements it without stealing keyboard focus.
4. If the full PAM conversation succeeds, revalidate the selected desktop and
   send exactly one existing start request. The chosen desktop is unchanged.
5. If fingerprint authentication times out, has no usable enrollment/device, or
   exhausts retries, the reviewed PAM profile proceeds to its password flow.
   Display the password question when it arrives. Do not synthesize a password
   request or collect a password while PAM is still waiting for a scan.
6. Cancel/Escape cancels the whole attempt and clears pending responses. An
   uncertain backend cancellation returns to existing daemon recovery; it does
   not immediately launch another authentication attempt.

The baseline has **bounded password fallback, not immediate method switching**.
Do not add a working-looking “Use password now” action to the existing protocol:
cancel/restart could simply enter the fingerprint module again. The waiting UI
may explain that password entry follows if scanning is unsuccessful, but only
when the administrator has selected the reviewed fallback profile. Without that
profile, use neutral wording and the daemon's actual instruction.

No reader progress percentage, retry count or selected-finger name is inferred
from translated text. A generic authentication icon/status is sufficient. An
optional administrator-owned `fingerprint_hint: false` config field may add
“Fingerprint login is available when configured” guidance; it is presentation
only, defaults off, and does not assert that a particular account is enrolled.
It must not enable a PAM module or alter authentication decisions.

## Authentication and lifecycle contract

```mermaid
sequenceDiagram
    actor User
    participant UI as Pearl greeter
    participant D as greetd / PAM
    participant F as fprintd / reader
    User->>UI: Choose account and desktop; Sign in
    UI->>D: create_session(username)
    D-->>UI: auth_message(info, scan instruction)
    UI->>UI: Display and retain instruction
    UI->>D: post_auth_message_response(null), once
    D->>F: Verify through pam_fprintd
    alt Fingerprint accepted by the complete policy
        F-->>D: Verification result
        D-->>UI: success after required policy checks
    else Fingerprint unavailable or unsuccessful
        F-->>D: Unavailable / retry limit / timeout
        D-->>UI: Password or subsequent PAM question
        User->>UI: Answer actual question
        UI->>D: post_auth_message_response(answer)
        D-->>UI: Overall success or authentication error
    end
    Note over UI,D: Only overall success can authorize the existing single session start
```

This is a representative exchange, not a mandatory message order. PAM may issue
multiple statuses, request another factor, succeed without an initial instruction,
or deny account/session policy. The implementation must handle those variants.

| Input/event | Required handling |
| --- | --- |
| `auth_message` with `info` or `error` | Render literal text, announce appropriately, then schedule one null acknowledgement |
| `auth_message` with `secret` or `visible` | Wait for the user's response; never auto-answer |
| Top-level authentication `error` | Terminal failure path; never acknowledge as if it were an informational message |
| `success` during authentication | Overall backend decision; allow existing selection revalidation/start sequence |
| Device absence/retry/failure described in text | Presentation only; do not derive success or fallback authority by string matching |
| Cancellation before queued acknowledgement | Invalidate callback and prompt generation; send no stale response |
| Cancellation during in-flight PAM | Preserve current uncertain-cancellation recovery, including termination where required |
| Success racing cancellation | Cancelled generation cannot submit start, including after output/account/session changes |
| Start reply lost | Preserve one-start/terminal-handoff behavior; never replay |

Implement automatic acknowledgements in the client/controller layer so behavior
does not depend on whether a monitor is present or how GTK schedules rendering.
Schedule through the main loop, capture connection/attempt/prompt generations,
and invalidate the callback during teardown/cancel/new attempt. Rendering must
copy any retained text before the wire response buffer is replaced. Enter must
not send a second response while an automatic acknowledgement is queued.

Retain a bounded, in-memory status history: at most four messages and 64 KiB total,
within the existing per-message limit. Clear it on account change, cancellation
or terminal handoff; never persist it. Keep current instructions readable during
in-flight operations instead of replacing them immediately with “Authenticating…”.
Use literal text rather than markup. Coalesce repeated accessibility announcements
without delaying protocol acknowledgements or suppressing a changed instruction.

Retain current frame, UTF-8, exchange and generation limits. Add an absolute
attempt deadline derived from the configured authentication timeout (120 seconds
by default, existing maximum 300), separate from inactivity and transport-progress
deadlines. Automatic info messages must not indefinitely extend an attempt.
The fingerprint phase's finite PAM budget must fit comfortably inside that
deadline; FP00 measures its behavior rather than assuming timeout × retries.

The greeter may clear/exit its own UI after cancellation, but only greetd/PAM can
release their reader claim. Prove device release and daemon recovery in FP06;
closing the greeter socket is not evidence that either happened.

## PAM policy and system integration

Produce **distribution-specific review examples**, with the existing password,
account, credential and session policy preserved. Keep login and locker examples
separate. The login profile belongs to greetd's authenticated-user service, not
the service that starts the dedicated greeter account; FP00 pins the exact names.

Candidate test settings are `max-tries=3 timeout=15` for the fingerprint module,
with debug disabled. These are test-profile defaults, subject to measured device
behavior and the full distribution stack. Do not ship an isolated `sufficient`
line as a universally correct PAM configuration: control jumps, faillock,
required factors, account checks and session setup need complete-stack review.

Required policy outcomes:

- A valid configured fingerprint can satisfy the optional authentication branch;
  account expiry, administrative denial and required additional factors still win.
- No enrollment, no reader, a busy device, module/service failure, or exhausted
  fingerprint retries can reach the preserved password path where policy permits.
- An incorrect fingerprint/password never succeeds; empty-password rejection,
  audit and lockout behavior remain consistent with the reviewed policy.
- Biometric login supplies no password to a wallet, keyring or encrypted-home
  unlocker. Test each desktop's resulting behavior and document any later password
  prompt or unsupported home-unlock configuration; never retain a password to
  conceal that distinction. This plan does not change disk-unlock policy.
- No blanket polkit permission lets the greeter inspect or enroll other accounts'
  fingerprints. No greeter/root execution shortcut, template copy, or new daemon.

Real account enrollment and verification take place only in an explicitly chosen
test guest/device workflow or a later administrator deployment. This planning
work does not enroll fingers, read biometric templates, install packages, modify
host PAM, change display-manager activation, or claim a physical reader.

## Source map

The following paths now contain the implementation and private validation.

| Location | Ownership/change |
| --- | --- |
| `src/greeter/controller.zig` | Passive-message classification and single-response authority; existing generation rules |
| `src/greeter/client.zig` | Scheduled null acknowledgements, callback lifetime and absolute attempt deadline |
| `src/greeter/screen.zig` | Retained scan/status presentation, focus, cancellation and real prompt visibility |
| `src/greeter/config.zig` | Optional presentation hint only; strict parsing/defaults |
| `src/greeter/status_history.zig` | Four bounded, owned passive messages; duplicate coalescing and secure clearing |
| `src/ui/auth/prompt_view.zig` | Backend-independent status presentation if useful to both surfaces |
| `src/lock/pam.zig`, `src/lock/screen.zig` | Verify existing nonblocking info-message behavior; fix only demonstrated locker gaps |
| `tests/integration/test_greeter_ipc.py`, `test_greeter_ui.py` | Replace manual-info expectations; add realistic passive conversations |
| `tests/fixtures/pam.zig`, `tests/fixtures/greetd/` | Synthetic fingerprint-style flows and failure cases |
| `tests/integration/test_fingerprint.py` | Focused private regression matrix and evidence aggregation |
| `tests/integration/test_fingerprint_upstream.py`, `tests/fixtures/fingerprint/` | Pinned upstream PAM module over a private mock D-Bus reader |
| `scripts/prepare-fingerprint-pam.py` | Hash-verified upstream test dependency preparation; no install/download |
| `packaging/greeter/fingerprint/` | Versioned, uninstalled PAM review examples and prerequisites |
| `docs/FINGERPRINT_LOGIN.md` | User/admin behavior, supported baseline, setup and rollback requirements |
| `artifacts/fingerprint/<candidate>/` | Separate private/real-device results, hashes and release gate |

No direct libfprint/fprintd bindings are needed for this design. Continue using
generated Ghostty GTK bindings and Zig 0.16.0; no small C bridge is introduced.
Avoid extending `protocol.zig` with invented fingerprint fields in baseline mode.

## Delivery tasks

### FP00 — Pin the fingerprint/PAM contract

**Depends on:** existing greeter contract record. **Deliverables:** fingerprint
compatibility section, fixture descriptions and a real-test prerequisite list.

1. Pin greetd and distribution patches, fprintd/libfprint/PAM versions, the
   authenticated greetd service name, and a complete candidate PAM profile.
2. Inspect the pinned `pam_fprintd` conversation, return values and finite timeout
   behavior. Record typed styles/ordering using synthetic messages; do not save
   production account names, passwords or biometric data in fixtures.
3. Identify supported test hardware and enrollment procedure. Record device ID,
   driver and firmware version where available, without publishing serial numbers.
4. Trace cancellation while greetd is blocked in PAM and record how its worker
   and fprintd claim are released. Existing source inspection is not hardware proof.
5. Define separate guest-account cases: enrolled, unenrolled, denied/expired,
   wrong password, and a policy requiring an additional factor.

**Done when:** contracts and finite budgets are pinned, or exact unavailable
packages/hardware/backend behavior are recorded as gates. Continue private tasks
when hardware is missing; leave real acceptance open.

### FP01 — Prepare optional policy and fallback examples

**Depends on:** FP00. **Deliverables:** proposed packaging directory and policy
truth table in `docs/FINGERPRINT_LOGIN.md`.

Create complete, versioned guest-only examples for greetd login and the fixed
`pearl` locker service. Explain every PAM control transition. Preserve the
distribution's account/session and password policy, and establish finite fallback
for no-device/no-enrollment/error/retry-limit cases. Keep examples out of active
`/etc/pam.d` and package install hooks. Document keyring/home limitations per test
desktop. Reject infinite module timeout/retry settings in the reviewed profile.

**Done when:** the examples are reviewable and the truth table covers success,
fallback, denial, lockout and required-factor behavior. Real PAM proof is FP06.

### FP02 — Advance passive greetd messages safely

**Depends on:** FP00. **Deliverables:** controller/client changes and focused tests.

Introduce a pure decision for user-input versus passive messages. Queue one null
response for each info/error conversation message and preserve visible/secret
input behavior. Add generation-safe GLib source cleanup and the absolute deadline.
Keep terminal errors distinct from error-style conversation messages. Ensure a
burst yields to the main loop and stops at existing exchange/size limits.

Update the current info-ack tests: a normal passive flow must complete without
Enter. Add tests for queued-ack cancellation, duplicate Enter, stale callbacks,
consecutive info/error statuses, immediate success, additional-factor questions,
deadline exhaustion and top-level denial.

**Done when:** passive flows progress without input; only overall backend success
can authorize a start; no secret/visible question is automatically answered.

### FP03 — Present scanning and password fallback

**Depends on:** FP02. **Deliverables:** GTK status behavior, optional hint config,
private screenshots and accessibility assertions.

Keep actual instructions visible while waiting and show secure entry only for
an input question. Add bounded status retention and announcements; keep Cancel
reachable by keyboard. Hide the manual Continue action for passive messages.
Do not show an immediate method-switch button in baseline mode. Preserve themes,
high contrast, reduced motion, short-screen scrolling, output movement/clearing
and one prompt owner. Clear any stale password on every transition to passive
processing. Confirm repeated status messages do not steal focus or churn layout.

**Done when:** keyboard-only mock fingerprint success and fallback-to-password
both complete without extra Enter presses or a stale response; cancelled/output-
lost attempts cannot start a desktop. Capture dark/light/GTK and large-text cases.

### FP04 — Validate fingerprint-style locker conversations

**Depends on:** FP00, FP02; FP03 for shared presentation changes.
**Deliverables:** locker fixtures, targeted fixes if needed, regression evidence.

Exercise the fixed current-UID `pearl` helper with info/retry/success, password
fallback, additional factors, account denial, disconnect and cancellation.
Keep its no-reply handling for PAM info/error messages. Ensure an old `waiting`
state cannot leave password entry active during passive scan processing.
Preserve helper kill/reap, lock acknowledgement, 90-second timeout and account
validation. Do not introduce arbitrary usernames/services or a second parallel
PAM process. Run the existing locker/security suites after any shared change.

**Done when:** the fixture-backed locker remains locked on every failure/cancel,
and unlocks only on complete PAM success while the compositor lock is acquired.
Physical fingerprint unlock remains a separate FP06 result.

### FP05 — Automate adversarial and resource validation

**Depends on:** FP01–FP04. **Deliverables:** proposed `test-fingerprint` build
target, private matrix runner and `artifacts/fingerprint/<candidate>/`.

Cover no input after info, error-style retries, localized/non-Latin/long statuses,
malformed/oversize/unknown messages, stalled backend, service loss, and repeated
attempts. Race success against cancel, pending automatic acknowledgement, output
loss, user/session changes and selected-entry replacement. Assert one start with
the correct frozen desktop, and no start from a scan-status string.

Keep scenarios faithful to greetd's request/response protocol: fake fprintd result
signals alone do not exercise login. Test the actual PAM module over a private
bus or in a guest only if FP00 establishes that supported fixture mechanism.
Otherwise label the synthetic PAM/greetd layers precisely.

Run 1,000 mock attempt/cancel cycles with no live PAM accounts; retain the existing
greeter CPU/PSS/growth targets. Check descriptors, GLib sources, pending-ack
cleanup and process teardown. Separate GUI waiting costs from reader/daemon costs.

**Done when:** private tests and applicable greeter/locker regressions pass, logs
contain no responses, and test hooks remain absent from production artifacts.

### FP06 — Prove real login, fallback and device release

**Depends on:** FP01–FP05 and the greeter's restricted-host/real-login prerequisites.
**Deliverables:** pinned VM and physical-device reports, each with pass/fail/not-run.

Use a disposable guest with an appropriate passed-through supported reader, or
a separately authorized dedicated test machine. Software emulation alone does
not prove fingerprint hardware support. Keep a password-capable recovery console
and snapshot/config backups. Enrollment uses existing fprintd tooling inside this
test environment; it is not an action performed by the greeter.

Execute the acceptance matrix below. Confirm the reader becomes available again
after cancellation, UI/compositor death, daemon recovery and logout. Test a real
scan completing concurrently with cancellation and reject any later login from
that cancelled attempt. Record actual scan-to-result, timeout-to-password and
cancel-to-device-release timings; exclude biometric identifiers and sample data.

**Done when:** all required real-device and desktop cases pass, or each missing
case remains an explicit release gate. Mock results cannot close this task.

### FP07 — Document and stage the fingerprint-capable candidate

**Depends on:** FP05; public acceptance also needs FP06.
**Deliverables:** final admin/user documentation, optional package examples,
reproducible binaries and a fingerprint-specific release gate.

Document prerequisites, the sequential fallback experience, setup through the
chosen distribution's supported PAM tooling, and restoring the exact previous
policy. Prepare guest-tested activation/rollback commands with backups before
any later host-deployment request. Keep enrollment administration separate.
Reproduce affected production binaries and verify ordinary Pearl/password-only
installations do not gain a hard dependency on fingerprint hardware or fprintd.

Update the greeter checklist's manual info-ack expectations to the new contract;
do not rewrite historical evidence as if it tested fingerprints. Record private
tests, real PAM/device evidence, desktop integration and accessibility separately.

**Done when:** the staged candidate and recovery instructions are reviewable,
and its gate accurately reflects FP06 and the parent greeter release gates.

## Required acceptance matrix

| Case | Expected result / evidence level |
| --- | --- |
| Correct enrolled finger | Complete PAM/account success; one selected-session start; private + real reader |
| Incorrect finger / retry limit | No login from scan status; finite password fallback under test policy; private + real |
| No enrollment / missing or unsupported reader | Password remains usable; no Pearl-generated account-enrollment disclosure; real policy |
| Reader busy / unplugged / fprintd restart | Bounded failure/fallback or existing controlled recovery; reader can be reclaimed; real |
| No scan at all | Measured finite path to password; no extra Enter required to advance passive messages; real |
| Fingerprint match with denied/expired account | No session start or unlock; actual account policy tested |
| Fingerprint followed by required factor | Subsequent question must be answered; no early success; private + real policy |
| Cancel at each message/scan boundary | No stale ack/start; owned cleanup and scanner release; private + real |
| Password-only installation | Existing login/unlock works without fprintd installed |
| Pearl/Aqueous, GNOME Wayland, Plasma Wayland, standalone compositor, X11 desktop | Fingerprint login, native lock behavior, logout and next login; record wallet/home behavior and absence of Pearl services in other desktops |
| Configured UWSM profile | Separate handoff/environment/logout acceptance; inherited parent gate |
| `pearl-lock` | Current-UID scan and password fallback, cancel stays locked, account denial stays locked; real reader |
| Themes/output loss/keyboard/Orca | Readable retained status, private fields, no forced Enter for status, no stale ownership; private + physical accessibility |
| 1,000 cycles and passive-message flood | Bounded memory/FD/source count; no real-password lockout load |

## Optional future immediate-method contract

If immediate password selection or simultaneous methods becomes a requirement,
first propose a **separate greetd/backend extension**, not a Pearl workaround.
It needs authenticated capability negotiation, an administrator-owned allowlist
of method identifiers, authoritative method/status events, attempt IDs, bounded
cancellation with worker/reader teardown, and one final PAM/account/session
decision. An untrusted greeter must not choose arbitrary PAM service names.
Concurrent stacks additionally need explicit success arbitration and teardown
of the losing worker. These capabilities are not present in the pinned baseline.

Write an upstream dependency document before implementing that extension. Do not
send unknown IPC fields, invoke `fprintd-verify` as login authority, claim a reader
from the GUI, or run the locker's helper to impersonate a greetd login.

## Implementation checklist and agent instructions

- [x] FP00: greetd/PAM/module source and local policy hashes pinned; absent fprintd/libfprint packages and missing real-reader/VM acceptance recorded.
- [x] FP01: complete review-only Arch profiles and fallback truth table; real Linux-PAM control flow tested with synthetic module results.
- [x] FP02: automatic passive-message acknowledgement, stale-generation rejection and absolute deadline implemented and tested.
- [x] FP03: retained status, private input visibility, keyboard/GTK themes and scan-only/password-fallback flows validated.
- [x] FP04: 20 locker checks and 20 existing security checks pass; physical fingerprint unlock remains separate.
- [x] FP05: private protocol/PAM/resource tests, eight upstream-module mock-bus cases and production-hook exclusion checks provided.
- [ ] FP06: supported physical reader, real fprintd/polkit, greetd/PAM session lifecycle, desktop matrix and Orca acceptance remain unrun.
- [ ] FP07: package examples, reproducibility tooling, documentation and release gate delivered; guest activation/rollback and public release acceptance remain unverified.

> Continue from the checklist and candidate evidence; preserve completed work.
> Resolve the real-reader/guest and parent greeter dependencies before claiming
> production acceptance. Recheck the current source and preserve unrelated work. Use Zig
> 0.16.0 and existing generated bindings. Keep PAM/greetd authoritative, preserve
> password fallback and installed-desktop selection, and distinguish passive
> status acknowledgement from answering a question. Do not change host PAM,
> enroll real fingerprints, claim a physical reader or deploy a display manager
> without explicit authorization for that environment. Continue private work
> when a backend/hardware dependency is missing and record the exact gate.
> Do not mark real-device or parent greeter acceptance complete from mocks.
