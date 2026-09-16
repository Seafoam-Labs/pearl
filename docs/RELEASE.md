# Release candidate and acceptance

Qt/Darkly integration is opt-in at runtime. Stable/Git packages build separate
Qt probes, declare QtEngine/application-only Darkly optional dependencies, and install the direct-login
and UWSM environment hooks without activating management. The shell remains a
GTK application. [Qt release evidence](../artifacts/qtengine/README.md) covers
private native consumers, Settings commits and staged packaging. Fresh physical
login/activation propagation and screen-reader speech are still acceptance gates;
no Flatpak-wide support is claimed. Before downgrade/removal, disable Qt management
and complete conditional restoration using the [recovery procedure](QT_THEMING.md#shared-files-conflicts-and-recovery).
Preserve user ownership records; package scripts must not remove them.

Pearl `1.0.0-rc.2` targets Aqueous exclusively and builds with exactly Zig 0.16.0.
This candidate adds current-master transactions, collection forms and native capture.
This is a release candidate: physical, actual login-session, screen-reader and
visual/presentation signoffs remain required. The project also needs its owner's
license selection; `LicenseRef-Pearl-Unlicensed` records the current absence of a
project grant. It is not an open-source license. Do not publish this candidate as
an accepted 1.0 release. The previous candidate gate is `artifacts/aqueous-master/gate.json`. The 0.8.2
integration has separate [automated evidence](../artifacts/aqueous-082/README.md);
that evidence does not grant public release acceptance.

## Build and package

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Drelease=true -Doptimize=ReleaseSafe
python3 scripts/release-source.py --output /tmp/pearl-release-source
python3 scripts/release-reproduce.py
python3 scripts/release-package.py
```

`-Drelease=true` requires ReleaseSafe and strips production binaries. Source
archives normalize order, ownership, modes and timestamps using the recorded
`SOURCE_DATE_EPOCH`. They include source, pinned dependency hashes, generated
binding inputs, tests, packaging and documentation; local caches, DMS reference
assets and test artifacts are excluded. The generated Arch recipe contains the
actual archive SHA-256, never `SKIP`. Run `makepkg` beside the archive and generated
recipe, or use the private package script. Neither path installs the package or
enables services. Do not use the template PKGBUILD before replacing its hash via
the source generator.

For the latest upstream Git revision, use the standalone
[`pearl-git` recipe](../packaging/arch-git/PKGBUILD):

```sh
cd packaging/arch-git
makepkg
```

This fetches the upstream repository's default branch and generates a version
from its release metadata, commit count and abbreviated commit hash (for example,
`1.0.0rc2.r22.ga002d24`). It uses the same dependencies, ReleaseSafe build and
checks as the release recipe, with `-Dcpu=baseline` for baseline x86-64 CPU
compatibility. The moving Git source uses `SKIP` for its checksum;
the release archive recipe remains checksum-locked. Install the resulting package
with `pacman -U`; `makepkg` alone only builds it.

`pearl-git` can be installed alongside `pearl`. Its commands are `pearl-git`,
`pearlctl-git`, `pearl-lock-git` and `pearl-settings-git`; its user unit is `pearl-git.service` and its
desktop launcher is **Pearl Git Settings**. The Git shell launches its own locker,
which uses `/etc/pam.d/pearl-git`. Package metadata, documentation and licenses live
under `/usr/share/pearl-git`, `/usr/share/doc/pearl-git` and
`/usr/share/licenses/pearl-git`. The Git direct-start example is
`/usr/share/doc/pearl-git/examples/aqueous-init-pearl-git`.
Both builds use the same user preferences and session control socket, so run one
shell per session and use the matching startup command or service.

Installing `pearl-git` alone does not select a shell or change UWSM arguments.
For the **Aqueous-Git** desktop, run `aqueous-welcome-git` and choose Pearl;
setup installs `aqueous-shell-pearl-git` and saves the choice for the next login.
For **Aqueous-Intel-Git**, use `aqueous-welcome-intel-git` and its matching preset.
These integrations must launch `pearl-git` and route actions through
`pearlctl-git`. They own startup; leave the standalone `pearl-git.service`
disabled to avoid duplicate shells.

The legacy combined **`aqueous-git` package** still uses the **Aqueous** login
entry. For that session, disable the previous shell's startup, then run
`systemctl --user daemon-reload` and `systemctl --user enable pearl-git.service`
as the session user. Log out and back in. No additional `uwsm start` arguments
are required: Aqueous finalizes its environment and UWSM starts the enabled unit.
The package prints these setup instructions on installation and upgrade.

The reproduction script builds in two fresh extraction roots and compares all
four production binary hashes. It can copy the already downloaded `zig-pkg`
cache; otherwise Zig fetches its hash-pinned dependencies. This proves identical
binaries for the recorded compiler, libraries and architecture; it does not claim
cross-distro reproducibility. The package script runs normal dependency checks and
`check()` with no `--nodeps`, `--nocheck` or dependency installation. Its package,
source archive, recipe, `.BUILDINFO`, `.PKGINFO`, payload list and hashes remain in
`artifacts/aqueous-master/package`. Package container byte reproducibility is not asserted;
production ELF and source archive reproducibility are checked separately.

The payload contains `pearl`, `pearlctl`, `pearl-lock`, `pearl-settings`, embedded GTK resources and
original icons, settings desktop entry, reviewed PAM policy, user unit, release
metadata, docs, examples and third-party notices. The installer requires an
absolute private `DESTDIR`; never use it as a live-system installer. Debug probes,
instrumented lockers and fixture PAM modules are excluded from the package.

| Runtime | Conservative package floor |
| --- | --- |
| GTK4 / GLib / gtk4-layer-shell | 4.22.5 / 2.88.3 / 1.3.0 |
| libpulse / PAM / polkit | 17.0 / 1.7.2 / 127 |
| glibc / Wayland / Pango | 2.44 / 1.26.0 / 1.58.2 |
| GdkPixbuf / Cairo / systemd | 2.44.7 / 1.18.4 / 261.3 |
| Optional matugen / NetworkManager / BlueZ | 4.2.0 / 1.58.1 / 5.87 |
| Optional UPower / power-profiles-daemon / UWSM | 1.91.4 / 0.30 / 0.26.7 |

Arch epochs are preserved in the recipe. These are tested conservative floors,
not evidence that every older library is incompatible. Matching compositor,
aqueousctl and helper are built from `1d038dc3bafa0044d9599f8f51f84105a6a85bb3`.
The compositor enables Vulkan effects against the recorded patched wlroots;
private tests select pixman or Vulkan explicitly. Production tool hashes, helper
0.8.0 and dependency hash are separate entries in `packaging/release.json`.
Test-only crash/fault binaries are labelled separately and never packaged.
Aqueous's installed package currently provides only the unversioned
virtual `aqueous`, so the package depends on that name. A package version alone
cannot certify Pearl's native protocol and settings capabilities. Startup/runtime
handshakes and the [compatibility contract](COMPATIBILITY.md) enforce them. Review
that contract when updating Aqueous. Optional missing services leave dependent
controls unavailable; they do not prevent static theming or basic shell startup.

## Direct and UWSM startup

Both paths require the live Aqueous `WAYLAND_DISPLAY`, `AQUEOUS_SOCKET`,
`XDG_RUNTIME_DIR`, an `Aqueous`, `Aqueous-Git` or `Aqueous-Intel-Git` desktop
identity and Wayland session type. The corresponding IPC directories are
`aqueous`, `aqueous-git` and `aqueous-intel-git` under `XDG_RUNTIME_DIR`. Never
copy socket values from a prior login or a nested compositor into the host user
manager. `pearl --check-environment` checks launch prerequisites and IPC socket
existence, then exits before GTK. The running application additionally validates
IPC/native display identity; the preflight alone does not prove a connection.

For direct startup, launch `/usr/bin/pearl` from Aqueous's post-initialization
command with its live environment. `packaging/examples/aqueous-init-pearl` is a
minimal command example. The owner of that session must stop/reap Pearl on logout.
Keep the shell command separate from compositor configuration helpers and replace
only the previous shell's startup command. Save the original first.

For UWSM, Aqueous initialization must export/finalize its live environment before
`graphical-session.target` starts Pearl. The env example adds `AQUEOUS_SOCKET` to
`UWSM_FINALIZE_VARNAMES` without hardcoding a value. The packaged user unit belongs
to `graphical-session.target`, rejects missing or explicitly nested environments,
and runs the preflight. Enable it for a future login only after disabling the
previous shell's startup path; do not enable both direct and service startup.
Current Aqueous initialization's private contract tests cover UWSM, direct
D-Bus/systemctl exports and nested isolation using mocks. Real UWSM startup and
logout lifecycle still require the manual signoff below.

`KillMode=process` is intentional: an active locker survives a shell service
restart and must finish through normal authentication. PAM's packaged `pearl`
service includes the distribution's `system-auth` auth/account stacks. The locker
is a normal 0755 binary, with no setuid bit or custom permissive PAM rule. Arch
marks `/etc/pam.d/pearl` as a backup file. Private PAM fixtures prove control flow;
the user's actual PAM policy, failure handling and suspend/resume require physical
acceptance. Never test a release by replacing host PAM with fixture policies.

See [MIGRATION.md](MIGRATION.md) for offline import, revision-safe apply, backup
restoration and returning to DMS. No script in this release changes the running
shell or host service enablement.

## Automated and human evidence

Standalone Settings has a complete private acceptance target,
`zig build test-settings-acceptance -Doptimize=ReleaseSafe`. It includes the
normal-window Aqueous UI checks and the affected shell regressions. The release
functional matrix additionally requires `test-settings-presentation`; the master
UI gate matches both the production Pearl and Settings hashes. See the
[S6 review](../artifacts/settings-app/s6/REVIEW.md) and
[physical/Orca checklist](../artifacts/settings-app/s6/MANUAL.md). Automated success
does not fill the separate manual release signoffs.

```sh
python3 scripts/release-validate.py
PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-master" ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-release-performance -Drelease=true -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-master-ui -Drelease=true -Doptimize=ReleaseSafe
python3 scripts/release-gate.py
```

Private integration tests require permission to create local sockets and run a
headless compositor. They use temporary HOME/XDG paths, session buses, synthetic
system services and test-only PAM. The regression runner records each exit code,
command and complete log, continues after failures and returns nonzero if any
check fails or the source fingerprint changes during the matrix. Private prefixes
verify their recorded tool hashes before startup. Captures are under each target's output directory. Earlier reference
comparisons remain in T06–T15 evidence; current screenshots require visual review,
not a claim of pixel parity based on successful capture.

The performance report names the machine, CPU, kernel, renderer, output geometry,
exact production binary, every idle/PSS sample, startup measurements, popup
acknowledgements and 100-cycle checkpoints through 1,000 cycles, including ten native preview/revert transactions and ten
canonical helper writer-lock contentions. PSS apportions
shared libraries across mappings and includes Pearl descendants; the compositor
is excluded. Idle measurement uses two virtual outputs, static wallpaper, no
active player and 60 seconds after warmup. Locker idle cost is recorded separately
by the T13 suite. A 32 MiB retained-growth alarm detects large soak regressions;
finite-duration testing alone cannot establish absence of every leak. GUI frame
presentation, cold-cache starts and real keybinding-to-visible timing are not
substituted by CLI acknowledgements.

Copy `docs/release-signoff.example.json` to `artifacts/aqueous-master/manual.json` only when
collecting real review evidence. Each passed item needs reviewer, date, machine,
notes, a relative evidence file and its SHA-256, plus the exact package binary
hashes at the top level. Keep failed or unperformed items pending. The gate checks
all automated suites, package and binary identity, matching source reproduction,
license and every manual item; it exits nonzero while anything is missing.

| Signoff | Required observation and retained evidence |
| --- | --- |
| `direct-login` | Fresh user/session starts one Pearl from live Aqueous environment, handles compositor exit, logs out cleanly and restores saved DMS startup |
| `uwsm-login` | Real managed login exports correct socket/display before service startup; duplicate prevention, logout, restart and independent locked helper behave correctly |
| `visual-review` | Human compare bar/islands, dock, launcher, control center, notifications, lock and settings against DMS references in dark/light, compact/default, GTK theme and enlarged text; document intentional island/GTK deviations |
| `physical-displays` | Mixed DPI/rotation, physical hotplug while locked, GPU/driver identity, native blur/no effects, VRR/HDR interactions; Intel/AMD and NVIDIA evidence or an explicitly narrowed release scope |
| `physical-security` | Real PAM rejection/success, polkit agent interaction, lock before suspend, lid/DPMS/resume, restart while locked, output recovery without exposing session content |
| `hardware-services` | Actual network scan/connect, Bluetooth pair/cancel/reconnect, audio routing, brightness, battery/profile feedback and unavailable-service behavior |
| `accessibility` | AT-SPI/Orca speech, names/roles/states, focus order/restoration, keyboard-only workflows, large text, reduced motion, 4.5:1 normal text and 3:1 important indicators including generated palettes |
| `presentation-performance` | Warm keybinding-to-visible <100 ms, search p95 <50 ms for 2,000 apps, frame times at 60/120 Hz, cold startup separately, GPU/refresh metadata and raw traces |

## Ownership, idle and failure audit

Clock updates are boundary-driven; service property refreshes are signal-driven
with one-shot coalescing timers. MPRIS has eight player slots; artwork uses one
cancellable worker, at most 2 MiB encoded input and a 256 px output. Tray state has
32 items with 128 menu nodes per item. Notification history holds 64 records and
up to eight actions each. The Aqueous icon cache holds 32 entries/8 MiB decoded
pixels and 16 queued fetches. Clipboard history holds 20 entries/16 MiB total,
with 256 KiB text and 8 MiB image limits; it clears on lock. These bounds are
implemented in `src/services`, `src/aqueous/icons.zig` and their policy tests.

The existing regression matrix covers missing/replaced service owners, late
callbacks, queue limits, malformed input, failed save/generation, conflicting
settings edits, output rollback, lock failure and cancellation. No unconditional
idle polling or new resident migration worker is introduced. Native display status
polling exists only during an active lease. DMS import
is a short-lived offline CLI operation. Headless GTK keyboard/role tests are
retained; they do not replace a real assistive-technology session.

Third-party notices are shipped from `bindings/licenses`. Generated Ghostty GIR
bindings, pinned protocol XML and translated PAM/Pulse headers retain their
upstream notices. GTK/GLib and other shared libraries remain dynamically linked;
the package does not copy their shared objects. Original Pearl icons are embedded;
DMS reference images are excluded from release source/package assets. Choosing
Pearl's project license remains an owner decision and blocks public release until
recorded consistently in LICENSE, package metadata and the source archive.

## Master migration and reproduction

Read [AQUEOUS_MASTER_MIGRATION.md](AQUEOUS_MASTER_MIGRATION.md) before switching.
Build the pinned tools with `python3 scripts/build-aqueous-master.py`; it archives
source into a private prefix and never changes the original Aqueous checkout.
Run `python3 scripts/aqueous-master-inventory.py` to capture matching contracts,
then `python3 scripts/aqueous-coverage.py` to regenerate coverage. For upstream
adversarial schema checks, create `.cache/aqueous-master/test-venv` with Python
3.11 and install `tests/fixtures/aqueous-master/schema-test-requirements.txt` there;
`python3 scripts/aqueous-master-upstream-tests.py` builds explicitly instrumented
fixtures and exercises upstream journal and preview failure boundaries.

The release gate requires matching master integration/capture, the upstream
adversarial baseline, capability coverage and private UI evidence in addition to
the existing regression, performance, package, reproduction and human checks.
Current-master hardware refusals and unavailable scene color metadata are expected
gates, not evidence that those features passed. Previous candidate evidence in
`artifacts/t16` is preserved and is not reused to certify these binaries.

Use `python3 scripts/render-master-evidence.py` after validation to refresh the
local evidence index and screenshot gallery. It never grants manual acceptance.
