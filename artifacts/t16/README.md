# T16 release evidence

The implementation supplies an Arch release candidate, offline DMS import and
rollback, session startup preflight, reproducible build checks and a fail-closed
release gate. **This is not an accepted public 1.0 release.** Physical hardware,
actual direct/UWSM login, human visual/presentation, AT-SPI and project-license
gates remain pending. See [the release workflow](../../docs/RELEASE.md) and
[migration guide](../../docs/MIGRATION.md).

| Evidence | Scope |
| --- | --- |
| [gate.json](gate.json) | Current automated and manual gate status |
| [environment.json](environment.json) | Machine, compiler, installed library versions, source revisions and private compositor hash |
| [functional/metadata.json](functional/metadata.json) | Full unit and 15 integration targets; commands, exit codes, duration and previous failed attempts |
| [performance/metadata.json](performance/metadata.json) | Production idle/startup/PSS samples and 1,000-cycle soak |
| [reproducibility/metadata.json](reproducibility/metadata.json) | Two fresh extraction roots, source archives and three identical production binary hashes |
| [package/metadata.json](package/metadata.json) | Normal makepkg dependency/build/check/package result and payload hashes |
| [package/PKGBUILD](package/PKGBUILD), [BUILDINFO](package/BUILDINFO), [PKGINFO](package/PKGINFO), [files.txt](package/files.txt) | Checksum-locked recipe, actual build environment and installed payload |
| [startup contract](startup/aqueous-init-contract.log) | Upstream direct/UWSM environment-export tests with private HOME and mocked service commands |
| [captures.html](captures.html) | Current captures with links to earlier DMS comparison evidence |

The produced package and source archive are retained locally in `package/` and
ignored by Git; rebuild them with `scripts/release-package.py`. Nothing was
installed into the host root or enabled in the host service manager.

Measured on a Ryzen 9 9950X3D with two 1280×720 headless outputs, Aqueous pixman and
GTK cairo: warm startup to acknowledged bar reservation p95 **52.2 ms**, idle
**0.017% of one core** over 60 seconds, maximum idle **33.7 MiB PSS**, 1,000 popup
cycles with ten virtual reconnects and repeated private service-owner replacement.
Retained PSS grew **1.73 MiB** from the 100-cycle warmup checkpoint. Popup CLI
acknowledgement p95 was **3.85 ms**; that is not keybinding-to-visible latency.
PSS apportions shared libraries and excludes the compositor. T13's lock report
is [functional/test-lock/report.json](functional/test-lock/report.json); the
performance idle run has no active locker or transient generator.

Initial failures are retained in the functional report's `previous_attempts` and
`.attempt-1.log` files. The surface test had assumed a fixed 48-pixel reservation,
which is invalid after always-visible workspaces wrap on narrower outputs. It now
checks the compositor reservation against the measured bar height. The services
test exhausted its default 20,000-line Wayland diagnostic buffer before late
keyboard assertions; its bounded capture is now 100,000 lines and failure to
refocus is explicit. Both corrected tests pass independently and are rerun in
the consolidated matrix.

The installer destination guard was inspected statically; all actual installer
invocations used private temporary staging destinations. A proposed `/` negative
test was rejected by automatic review before execution and was replaced with
that safe check. No root-destination installer test was executed.

Visual inspection of the dark islands/dock and custom GTK-theme settings captures
confirms the intended detached islands and GTK styling remain present. The
synthetic GTK theme has low-contrast notebook labels; it is a compatibility fixture,
not an accessibility-approved palette. Full visual comparison, theme contrast
approval, real GPU presentation, physical PAM/suspend/output recovery and speech
validation remain explicitly unaccepted; successful screenshots do not close them.
