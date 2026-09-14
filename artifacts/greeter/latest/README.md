# Pearl greeter candidate evidence

This candidate contains the Pearl greeter implementation and **private test
evidence only**. It is not accepted for production login. No host PAM, display
manager, user account or VT configuration was changed.

The separate Aqueous checkout advanced during implementation from the recorded
baseline to `78a2d020bd93df26068408271b816f6ce6d6988a`, with additional uncommitted
capture work. This task did not edit that checkout. Its final status is recorded
in the verification file; neither those commits nor that working tree are
silently substituted for the private compositor hash in the UI report.

See [verification.json](verification.json) for commands, candidate source hashes,
package hashes and the staged payload location. The stripped production binaries
match [two independent fresh builds](reproducibility.json). Test executables
contain compile-time fixture hooks and have different hashes; they are excluded
from the staged package.

| Validation | Evidence |
| --- | --- |
| Pure framing/controller/desktop parsing | 8 tests; [unit log](unit.log) |
| greetd socket failures and conversations | 12 fake-daemon scenarios; [integration log](integration.log) |
| Catalog, session launcher and process ownership | Harmless commands and private fixtures; [component log](components.log) |
| AccountsService and logind | Private D-Bus services; [integration log](integration.log) |
| GTK themes, keyboard authentication, output changes, accessibility controls and stale selection | [UI report](ui/report.json), [screenshots](ui/session/greeter-material_dark.png), [UI log](ui.log) |
| 1,000 authentication/cancellation cycles | [Soak report](soak.json); mock accounts only |
| Existing locker | [15 checks](locker/report.json) |
| Existing session security | [20 checks](security/report.json) |
| Optional package and appearance export | [Package log](package.log) |

Resource results in the UI report measure a private software-rendered Aqueous
session with reduced motion enabled. Greeter and compositor PSS/CPU are recorded
separately over 65 seconds after warm-up. CPU ticks are sampling-resolution
measurements, not proof that a process consumes literally no CPU. The soak report
records retained PSS and descriptors at 10 and 1,000 mock cycles. These results do
not measure physical presentation, real PAM latency or a complete desktop login.
The one-second startup target remains unmeasured.

[release-gate.json](release-gate.json) retains the unresolved requirements:
restricted Aqueous hosting/input control, matched greetd distribution/PAM
semantics, real Wayland/X11 desktop and UWSM acceptance, compositor escape tests,
Orca/privacy and physical login/VT/output signoffs, and release licensing. The
production supervisor deliberately refuses to launch until the restricted host
contract is implemented and verified.

The [implementation checklist](../../../docs/GREETER_IMPLEMENTATION_PLAN.md#delivery-order-and-acceptance-checklist)
and [compatibility record](../../../docs/GREETER_COMPATIBILITY.md) distinguish
completed Pearl work from those remaining integration requirements.
