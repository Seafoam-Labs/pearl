# T12 verification

T12 includes native `pearl-lock` at the user's request: no swaylock handoff.
The independent Zig/GTK locker uses session-lock surfaces and Linux-PAM;
Pearl coordinates actual lock acquisition with logind sleep and idle policy.

All recorded builds use Zig 0.16.0, ReleaseSafe, generated bindings and the
pinned Aqueous revision in [metadata.json](metadata.json). Source and production
binary hashes identify this implementation; individual suites record their
instrumented binary hashes. Logs are in [checks/](checks/).

| Verification | Result |
| --- | --- |
| Production build | Passed |
| Pure, adapter and binding tests | 91 passed |
| [Private session security](latest/report.json) | 19 scenarios passed |
| [Preferences/settings regression](regression/preferences/metadata.json) | 21 groups passed |
| [Audio/power regression](regression/services/results.json) | 15 groups passed |
| [Application lifecycle regression](regression/lifecycle/results.json) | 12 groups passed |
| GIR, Wayland and PAM regeneration | Passed |
| [Package staging and production test-hook exclusion](packaging.json) | Passed |
| Zig formatting, Python syntax, shell syntax and diff whitespace | Passed |

The security suite uses private D-Bus authorities, real logind-style inhibitor
FDs, an isolated Aqueous display and a non-installed PAM fixture module. It
exercises actual compositor idle and session-lock acknowledgements, PAM
multi-message failure/cancellation/success and account denial, AC/battery policy,
authority/logind restart, confirmations, shell shutdown while locked, false
readiness, failed external sleep preparation, locker death and authenticated
recovery, and acknowledged compositor logout after GTK teardown.

Visually inspected captures:

- [Native Material dark lock](latest/session/native-lock.png)
- [Native Material light lock](latest/session/native-lock-light.png)
- [Native GTK theme lock](latest/session/native-lock-gtk.png)
- [Polkit identity choice](latest/session/polkit-identities.png)
- [Session controls](latest/session/session-controls.png)

The lock screenshots use fixture PAM prompts, not the host's credentials or
authentication policy. The pinned private Aqueous build permits these captures
while locked; screenshot rejection is not claimed. The polkit fixture validates
agent registration, identity presentation and cancellation, not successful
authorization by the host's real authority.

No host PAM file, user unit, compositor configuration, service ownership or power
state was changed. Actual hardware sleep/lid/resume, physical mixed-DPI hotplug,
production PAM and real polkit authorization require installation-specific
acceptance. T13 accessibility and long-run acceptance also remain pending.
See [SESSION_SECURITY.md](../../docs/SESSION_SECURITY.md) for commands, expected
outcomes, external delay-inhibitor limits and native locker recovery.
