# Fingerprint candidate evidence

This candidate implements Pearl's passive fingerprint/PAM conversation support.
**Production fingerprint login is not accepted.** No host PAM, enrollment, reader
ownership or display-manager configuration was changed by this work.

| Validation | Result / evidence |
| --- | --- |
| Core framing/controller/status bounds | 10 unit tests; [final checks](checks.log) |
| Fingerprint protocol | 9 cases against fake greetd; [report](report.json) |
| PAM conversation and policy jumps | 18 cases using real Linux-PAM with private synthetic modules; [report](report.json) |
| Pinned upstream pam_fprintd 1.94.5 | 8 cases on a private mock D-Bus reader, including retries/timeout/cleanup; [upstream report](upstream.json), [build provenance](upstream-provenance.json) |
| Passive status/cancellation soak | 1,000 cycles with no real accounts; [memory/FD report](soak.json) |
| GTK login/fallback/cancellation | 8 scenarios; [report](ui/report.json), [scan screenshot](ui/session/greeter-scan-material_dark.png), [large text](ui/session/greeter-scan-fingerprint.png) |
| Native locker | 20 checks including 5 fingerprint conversations; [report](locker/report.json) |
| Existing session security | 20 checks; [report](security/report.json) |
| General unit suite | 79 tests; [log](general-tests.log) |
| Existing greeter IPC/catalog/launcher/process/services | [Final checks](checks.log) |
| Package and production hooks | [Package log](package.log) |
| Fresh build reproduction | Three greeter binaries and the affected locker; [hashes](reproducibility.json) |

[verification.json](verification.json) records candidate hashes, staged package
location, source manifest and measured resource usage. Test executables contain
compile-time fixture support; they are excluded from production staging. The
upstream PAM module is also a non-installed test dependency, not a Pearl bridge
or bundled production module.

PAM-profile tests substitute module return values to exercise actual Linux-PAM
jumps/substack boundaries. They do not certify real faillock storage, homed,
account databases or login session policy. Upstream-module tests run real module
code but simulate the reader service and its ownership cleanup; they do not
prove physical release, real fprintd authorization or hardware matching.

UI CPU/PSS measurements cover a private software-rendered Aqueous display, with
reduced motion enabled, over 65 seconds. Greeter and compositor are recorded
separately. They are not scan/presentation or real login latency measurements.
The absence of local fprintd/libfprint while ordinary/private tests run establishes
that password-only Pearl does not gain a mandatory fingerprint dependency.

[release-gate.json](release-gate.json) lists each outstanding real-reader,
greetd/PAM, desktop and physical-accessibility case as not run. The restricted
Aqueous production-host gate remains closed. Parent greeter/locker evidence is
left intact; these artifacts do not retroactively certify the earlier candidate.

See [usage/policy instructions](../../../docs/FINGERPRINT_LOGIN.md) and the
[implementation checklist](../../../docs/FINGERPRINT_LOGIN_IMPLEMENTATION_PLAN.md).
