# Fingerprint login

Pearl supports passive PAM conversations through greetd: scan instructions and
retry messages advance automatically without pressing Continue. The daemon's
current instruction stays visible while it is processing. Password and other
input questions still require an explicit response. This is a PAM integration;
Pearl does not access readers, templates or enrollment data.

**Production fingerprint acceptance remains gated.** Private tests do not certify
a device, installed PAM policy or login session. The parent [greeter gates](GREETER_COMPATIBILITY.md)
also remain in force. See the [implementation checklist](FINGERPRINT_LOGIN_IMPLEMENTATION_PLAN.md).

## User behavior

Choose an account and desktop and activate Sign in. Follow the actual scan
instruction. With the reviewed optional policy, unsuccessful scanning proceeds
to password entry after a finite interval. There is no immediate method-switch
button: ordinary greetd 0.10.3 does not select a separate authentication method.
Additional required factors and account denial remain authoritative.

Escape cancels the entire attempt. A cancellation during an in-flight PAM call
may require restarting the greeter for daemon recovery. It never starts another
attempt in an uncertain backend state. A fingerprint status message containing
words such as “matched” or “success” cannot authorize a desktop or unlock.

The optional administrator setting `fingerprint_hint: true` adds generic guidance
to the greeter. It neither enables PAM nor checks whether the selected account
has enrolled fingers. The default is false. Appearance export does not carry it
from a user's preferences into login policy.

The client retains at most four passive messages (64 KiB of text) in volatile
memory. It clears them on cancellation/new attempt/handoff and never logs them
or submitted responses. Identical status announcements are coalesced. An absolute
attempt deadline uses `auth_timeout_seconds` (120 by default, maximum 300);
status floods and typing cannot keep an attempt alive forever. Cancellation and
start acknowledgement have their own existing bounded deadlines.

## Pinned inspection and unresolved dependencies

[baseline.json](../tests/fixtures/fingerprint/baseline.json) records package
versions and hashes of the inspected PAM configuration and upstream module.
The baseline is Arch-style pambase 20260616-1, PAM 1.7.2-2.1, greetd 0.10.3-2.1,
and Zig 0.16.0. fprintd and libfprint are not installed on the inspected host;
no enrolled device has been selected or claimed for this work.

The inspected upstream `pam_fprintd.c` is from **v1.94.5**. Scan selection/retry
callbacks send PAM info/error messages. Its verification loop sets a timeout
for each verification attempt; a no-match can start a new attempt, while timeout
returns unavailable after VerifyStop. Non-success cleanup releases the device;
success closes the bus and relies on daemon-side client-disconnect cleanup.
Do not infer physical release latency from source inspection.
[Pinned upstream source](https://gitlab.freedesktop.org/libfprint/fprintd/-/blob/v1.94.5/pam/pam_fprintd.c)

The candidate module settings are `max-tries=3 timeout=15 debug=off`. Fifteen
seconds is not a guaranteed end-to-end maximum: retries and D-Bus operations
contribute time. The actual fallback/device-release budget must be measured
with the installed stack and fit inside Pearl's overall attempt deadline.
[Module options and serialization](https://man.archlinux.org/man/pam_fprintd.8.en)

The greetd source baseline is 0.10.3 commit
`08efe60feceea8c81f9571c666880ff1e1c2e3ff`. Its default authenticated-user service
is `greetd`; its dedicated greeter service is `greetd-greeter` when available,
with fallback resolved by the daemon. The fingerprint examples target the former.
Distribution patches, real blocked-PAM recovery, reader/firmware support and
the full desktop matrix remain unverified. Inspect actual guest configuration
before applying service names or examples.

## Review-only Arch policy examples

The files under [packaging/greeter/fingerprint](../packaging/greeter/fingerprint/)
are optional review material. Staging places them under documentation, never in
`/etc/pam.d`. They are a profile for local password-capable test accounts, not a
drop-in policy for every Arch installation, systemd-homed, LDAP or MFA setup.

`greetd.example` preserves the inspected login restrictions and account/session
includes while substituting a private authentication substack. `pearl.example`
keeps the locker's fixed current-UID service and separate account validation.
The private substack is a copy of the pinned password-authentication sequence
with three explicit changes: an optional fingerprint branch, a **requisite**
faillock precheck, and omission of `nullok` on pam_unix. The latter two stop locked
accounts before scanning and reject empty passwords in this candidate.

| Step | Control and effect |
| --- | --- |
| faillock preauth | Requisite: denial stops before offering any factor |
| fprintd | Success skips exactly the next three modules (homed, unix, authfail); every other result continues to password policy |
| systemd_home | Existing success jump skips unix/authfail; acceptance of homed accounts remains unverified |
| unix | Success skips authfail; failure is retained |
| faillock authfail | Failure path terminates the substack |
| permit, env, faillock authsucc | Original completion path; required failures cannot be overridden |
| outer account/session | Original includes remain required after authentication |

PAM substacks bound these jumps; a module result cannot skip the outer account
checks. Custom required authentication factors must be outside the alternative
branch, and their results must remain required. Changing module order or adding
lines requires recalculating and testing jumps.
[Linux-PAM control semantics](https://man.archlinux.org/man/pam.conf.5.en)

| Policy input | Candidate result |
| --- | --- |
| Locked/precheck denied | Stop before fingerprint/password; no success |
| Fingerprint success, allowed account | Authentication branch succeeds; account/session checks still run |
| No device/enrollment, busy/unavailable, timeout, retry limit, module missing | Password branch runs; no implicit success |
| Wrong fingerprint, correct password | Password may succeed under the remaining policy |
| Wrong fingerprint and password | Fail through authfail; no reset via authsucc |
| Fingerprint success, denied/expired account | No login/unlock |
| Fingerprint success, additional required factor fails | No login/unlock |

Fingerprint no-matches do not each increment pam_faillock in this profile; failure
of the eventual password branch does. Confirm that policy against the guest's
lockout requirements. Do not enable module debug logging. Do not globally edit
system-auth or add permissive fprintd polkit rules.

## Desktop and hardware acceptance

Enroll a test account through existing authenticated fprintd tooling in a
disposable guest with a supported passed-through reader, or an explicitly chosen
dedicated machine. Do not enroll or inspect other users through Pearl. Device
IDs/driver versions belong in the test report; templates, samples, serial numbers
and production usernames do not.

Test fingerprint login and password fallback separately for Pearl/Aqueous, GNOME
Wayland, Plasma Wayland, a supported standalone compositor, and an X11 desktop.
Check logout followed by a different desktop, native locking, and any enabled
UWSM profile. For `pearl-lock`, test scan success, account denial, cancellation,
reader loss and password fallback while the actual compositor remains locked.

Record wallet/keyring and encrypted-home behavior per desktop. Fingerprint
authentication supplies no password to unlock those stores; a later password
prompt or an unsupported encrypted-home configuration must be documented.
No cached password is introduced to hide that limitation. Physical Orca speech,
private-field behavior and scan-to-result/timeout-to-password/cancel-to-reader-
release timings are separate acceptance results, not mock-test claims.

## Staging and reversible deployment

Build and run the private `test-fingerprint` target with Zig 0.16.0. It uses fake
greetd and a private PAM fixture, never installed host authentication policy.
The greeter's existing package staging script includes the example files only.
Ordinary Pearl builds do not link libfprint or require fingerprint hardware.

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-fingerprint -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-greeter-ui -Doptimize=ReleaseSafe -- --output artifacts/fingerprint/latest/ui
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-lock -Doptimize=ReleaseSafe -- --output artifacts/fingerprint/latest/locker
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-security -Doptimize=ReleaseSafe -- --output artifacts/fingerprint/latest/security
python3 scripts/greeter-reproduce.py --include-locker --output artifacts/fingerprint/latest/reproducibility.json
```

The additional upstream-module suite runs real `pam_fprintd` over a mock private
D-Bus service. It has passed eight cases, including three failed scans, timeout,
no device/enrollment, a busy reader, cancellation cleanup and account denial.
It does not test real fprintd/polkit, USB/SPI hardware, firmware, PAM session setup
or production greetd. Prepare its **non-installed test dependency** from the
pinned archive (SHA-256 `a026ef34c31b25975275cc29a5e4eba2b54524769672095a5228098a08acd82c`):

```sh
python3 scripts/prepare-fingerprint-pam.py --archive /path/to/fprintd-v1.94.5.tar.gz --output .cache/fingerprint-pam-1.94.5
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-fingerprint-upstream -Doptimize=ReleaseSafe -Dfingerprint-pam=.cache/fingerprint-pam-1.94.5/pam_fprintd.so
```

The preparation script verifies the archive/source hashes and uses the existing
C compiler, PAM and libsystemd headers to compile the upstream module unchanged.
That module is a private test dependency; no C bridge is added to Pearl and the
module is excluded from production staging. The script performs no download,
package installation or service activation. Source URL and tool/binary hashes
are recorded in its `provenance.json`.

Before any later activation, pin and snapshot the test guest; retain a working
password-capable console. Copy the exact current greetd/pearl/private-substack
files and their ownership/modes to a root-only backup. Review the complete
include graph and all profile differences, then install only the reviewed files
inside that guest. Never change `greetd-greeter` to the authenticated-user profile.
On failure, restore each previous file and remove only the newly created private
substack if it was absent in the backup, using the retained console. Confirm
password login before returning to fingerprint testing.

Guest-specific activation/rollback commands and physical signoff remain pending
the real test environment. These examples do not enable a display manager or
establish real greetd/PAM or desktop handoff acceptance.

The [fingerprint evidence](../artifacts/fingerprint/latest/README.md) records
private results separately from each unrun physical/real-login case.
