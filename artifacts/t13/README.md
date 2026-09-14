# T13 verification

The native locker remains an independent Zig/GTK session-lock client with a
separate Linux-PAM helper. T13 adds responsive and accessible input, secure GTK
entry buffers, strict response framing, validated readiness descriptors,
serialized output assignment and event-driven clock/retry updates.

| Verification | Result |
| --- | --- |
| Production ReleaseSafe build, Zig 0.16.0 | Passed |
| [Pure, adapter and binding tests](checks/unit.log) | 92 passed |
| [Dedicated native-lock scenarios](latest/report.json) | 15 groups passed |
| [Session security regression](regression/security/report.json) | 20 groups passed |
| [Staging and production test-hook exclusion](packaging.json) | Passed |
| Zig formatting, Python syntax and whitespace | Passed |

[metadata.json](metadata.json) records source and production binary hashes.
Each integration report records its actual instrumented binary hashes. The
source and ABI binding inputs remain the pinned Ghostty/GTK/PAM stack; no C
bridge or host library patch was introduced.

The dedicated suite exercises real keyboard input and GTK accessibility
properties, Caps Lock, mixed scale/rotation, 24 px base text, authentication on
a sole 320 × 240 logical output, oversized ASCII/UTF-8 response rejection,
helper crash/malformed framing/timeout/missing policy, Escape/Enter, duplicate
locker rejection, a broken readiness reader and an invalid readiness descriptor.

It also verifies 12 burst output reconnects, **100 settled reconnects**, all-output
removal/return, continued lock coverage and restored input. The final **65-second
idle sample** records CPU time, RSS, PSS, file descriptors, clock events and
authentication UI update counts in the report. That sample covers the locker
alone with authentication cancelled; shared library accounting is included in
RSS and apportioned in PSS. Output samples describe retained memory after every
25 settled reconnects. These are bounded measurements, not an indefinite soak.

Visually inspected captures:

- [Large text](latest/session/lock-large-text.png)
- [Rotated output at fractional scale](latest/session/lock-rotated-large-text.png)
- [Small output with focus scrolling](latest/session/lock-small-scrollable.png)
- [Material dark](regression/security/session/native-lock.png)
- [Material light](regression/security/session/native-lock-light.png)
- [Native GTK theme](regression/security/session/native-lock-gtk.png)

The private PAM fixture supplies the visible prompt text; it never uses a host
password. Tests run with fatal GTK warnings and verify that fixture credentials
do not appear in locker logs. GTK's accessibility test backend checks labels
and buffer types; it does not verify real screen-reader speech or session AT-SPI
access. The PAM timeout is shortened only in the non-installed instrumented
binary for the hang scenario. Production rejects the test hooks.

No host PAM configuration, display, service ownership or power state was changed.
Real hardware DPMS/lid/suspend/resume, physical hotplug timing, screen-reader
interaction and distribution PAM policy remain installation acceptance. The
queueing mitigation for gtk4-layer-shell 1.3.0 is documented without claiming
an upstream fix. See [LOCK_SCREEN.md](../../docs/LOCK_SCREEN.md) and
[SESSION_SECURITY.md](../../docs/SESSION_SECURITY.md).
