# Running Pearl tests

Use `python3 scripts/test.py` to discover suites, check prerequisites, prepare
private dependencies, and run tests. The runner uses the same Zig targets and
Python harnesses as direct development commands. `zig build integration` is only
the lifecycle suite; it does not run all integrations.

The runner supports x86_64 Linux and Python 3.12 or newer. The full native stack
is developed on Arch-based Linux. The fast group also runs on Ubuntu 24.04 in CI.
Other distributions can use `doctor` to identify required libraries and versions,
but their complete native setup has not been qualified.

## First setup

Clone Pearl into an ASCII path. Spaces are supported; non-ASCII paths have a known
limitation in the pinned Zig header translator. Run these commands from Pearl:

```sh
python3 scripts/test.py list
python3 scripts/test.py doctor --group integration
```

`doctor` reports missing system tools, library versions, Python imports, and
prepared fixtures. Once fixtures are available, it starts a short private
compositor and screenshot probe. It never substitutes the running desktop.

For core desktop integrations on Arch-based Linux, install the prerequisites:

```sh
sudo pacman -S --needed \
  base-devel git python python-pip python-pillow python-gobject pkgconf \
  gtk4 gtk4-layer-shell libpulse pam polkit curl libarchive libpng dbus grim \
  wayland wayland-protocols ttf-dejavu matugen meson ninja glslang \
  vulkan-headers vulkan-icd-loader mesa libinput libevdev libxkbcommon pixman \
  libdrm libdisplay-info libliftoff lcms2 seatd xorg-xwayland libxcb \
  xcb-util-errors xcb-util-wm xcb-util-renderutil hwdata wlr-randr wlrctl wtype \
  wl-clipboard pipewire pipewire-pulse libnotify desktop-file-utils at-spi2-core
```

Install the appropriate Vulkan driver for your system. `vulkan-swrast` supplies a
software Vulkan implementation for environments without hardware acceleration;
the compositor probe determines whether the selected environment actually works.
Headless outputs alone do not guarantee GPU-free rendering. Required native
library floors are also checked by Pearl's build graph.

Then prepare and run:

```sh
python3 scripts/test.py prepare --group integration
python3 scripts/test.py run --group integration
```

Preparation downloads the pinned Zig compiler if needed, creates a Python venv
with access to system PyGObject, fetches the exact Aqueous commit, and builds
patched wlroots plus matching compositor/helper binaries. It also fetches the
selected Zig dependency graphs. Dependencies and logs stay under `.cache/`.
The first build takes substantially longer than subsequent runs. Preparation
checks downloaded tool archives against `scripts/test-downloads.json`.

System packages are installed by the commands you choose to run. The runner does
not run sudo, activate services, replace a compositor installation, or change
PAM/greetd configuration. Test sessions create private HOME/XDG roots and buses.

For the fast checks on Ubuntu, the smaller setup is:

```sh
sudo apt-get install libglib2.0-dev pkg-config python3 tzdata
python3 scripts/test.py prepare --group fast
python3 scripts/test.py run --group fast
```

## Selecting tests

| Group | Coverage and extra requirements |
| --- | --- |
| `fast` | Model/Unicode and clock tests, Python release tooling and protocol traces, runner contracts, and Python inventory. |
| `native` | Compositor-free bindings, adapter, greeter-unit, theme/tooling checks. Profile-format validation additionally needs Lua and Neovim. |
| `integration` | Core lifecycle, settings, desktop, service, capture, security, and theme sessions; includes Vulkan-dependent coverage. |
| `greeter` | Private greeter protocol, UI, staging, and mock authentication cases. |
| `qt` | Qt 5/6 consumers and sessions. Install QtEngine and Darkly for both Qt versions, plus Qt development tools. |
| `plugins` | Wasm component host, discovery, UI, and input activity. Needs Rust with the `wasm32-wasip2` target and `rsvg-convert`; preparation downloads pinned component tools and Wasmtime. |
| `upstream` | Pinned Aqueous adversarial tests and private upstream pam_fprintd tests; requires systemd/PAM headers and the compositor build tools. |
| `apps` | Phyto, Dome, and Coral. Coral requires GtkSourceView 5, Enchant and dictionaries; Phyto cases need GVfs, Bubblewrap, Poppler, and FFmpeg. |
| `extended` | Long-running and aggregate acceptance suites. Aggregate targets intentionally repeat constituent scenarios to produce their own acceptance reports. |
| `release-regression` | The existing release matrix with ReleaseSafe and release stripping options. It is only part of release acceptance. |
| `all` | All registered unattended groups, including optional dependencies and release variants. |

`list` shows exact suite IDs, capabilities, and aliases. `list --json` also lists
explained exclusions for historical scripts, helpers, and manual measurements.
Missing prerequisites for a selected suite produce a blocked result and a nonzero
exit code. Optional groups are not silently skipped when selected.

```sh
python3 scripts/test.py list --group integration
python3 scripts/test.py run --suite test-settings-app
python3 scripts/test.py run --suite integration --suite test-services
python3 scripts/test.py run --group integration --dry-run
python3 scripts/test.py run --group integration --jobs 2 --fail-fast
```

`--jobs` limits Zig compiler parallelism. Suites run serially because some share
build outputs. A checkout lock prevents concurrent preparation/execution in the
same tree. Use separate checkouts for independent jobs. Direct Zig commands remain
available, but do not run them concurrently with the runner in the same checkout.

## Existing fixtures and offline use

An existing Aqueous Git checkout can supply the pinned source without being
modified. The pinned commit must exist in its object database:

```sh
python3 scripts/test.py prepare --group integration \
  --aqueous-source /absolute/path/to/Aqueous
```

To use already built production fixtures, pass `--aqueous-prefix` to `doctor`,
`prepare`, and `run`. The directory must contain `metadata.json`, matching binaries
and wlroots, and the pinned extracted source used by input fixtures. It is not
enough to point at `/usr` or an arbitrary compositor binary. Diagnostic plugin
variants remain separate managed builds.

```sh
python3 scripts/test.py doctor --suite integration --aqueous-prefix /path/to/fixture
python3 scripts/test.py run --suite integration --aqueous-prefix /path/to/fixture
```

The runner sets `PEARL_TEST_AQUEOUS_PREFIX`, `PEARL_TEST_AQUEOUS_SOURCE`, and the
fixture Python executable itself. For Qt plugins installed under a private prefix,
use `--qt-prefix /path/to/qtengine-installation`.

Prepare online before requesting `--offline`. Offline execution disables Zig
package fetching; offline preparation uses cached Git objects, tool archives,
Python wheels and Rust dependencies. A missing cached input is an error. This
option controls dependency fetching, not a network sandbox: private local HTTP
and D-Bus fixtures still operate. A moved Aqueous prefix with absolute provenance
paths is rejected and must be rebuilt in its new location.

## Results and reruns

Each invocation prints its evidence directory, normally
`.cache/test-runs/<unique-id>/`. Supply `--output` to choose a new directory;
existing directories are never overwritten.

```sh
python3 scripts/test.py run --suite test-settings-app --output .cache/my-settings-run
python3 scripts/test.py rerun --failed .cache/my-settings-run
```

Each run writes:

- `summary.txt`: selected suites, status, duration, and log locations.
- `results.json`: commands, source fingerprint including local edits, dependency
  versions, fixture provenance, statuses, and exit codes.
- `junit.xml`: one case per executed or selected suite, for CI report tools.
- Per-suite command logs and native screenshots/reports where supported.

Reruns include failed, blocked, timed-out, interrupted, and not-run suites. They
create new evidence and link the previous run. They do not combine previous passes
with changed source to claim a full current-tree pass.

The runner returns 0 only when every selected suite passed; 1 for suite failures
or timeouts; 2 for invalid selection or missing prerequisites; 3 for runner errors;
and 130 for interruption. Ctrl-C and timeouts clean up owned descendants, including
processes that launched in separate sessions. Unrelated processes are untouched.

## Common problems

| Symptom | Next action |
| --- | --- |
| Wrong Zig version | Run `prepare` for the selection. If changing the repository pin, update the verified download manifest too. |
| Missing `gi` or GTK typelib | Install the distribution's PyGObject and GTK/typelib packages. The managed venv inherits system packages. |
| Missing fixture or changed builder/library versions | Run `prepare` again; new input fingerprints get a separate fixture prefix. |
| Private compositor probe fails | Read the reported `smoke.log` and session logs. Check Vulkan support and permission to create local sockets. |
| Tool archive checksum mismatch | Keep the failure evidence; check the pinned URL/hash. Do not bypass integrity checking. |
| Unknown/unclassified test | Update the suite registry or provide a specific exclusion, then run `check-registry`. |
| A checkout is already in use | Wait for its test/preparation process or use another checkout. Do not delete an active lock. |

## Release checks and CI

`scripts/release-validate.py` delegates execution to the runner and preserves the
legacy metadata consumed by `scripts/release-gate.py`. Its `--resume` option only
retains earlier results when both source and environment fingerprints match.
Evidence from the old runner needs a new output directory. Partial selections
cannot satisfy the full release gate.

```sh
python3 scripts/release-validate.py --output .cache/release-functional
python3 scripts/release-validate.py --output .cache/release-functional \
  --resume --targets test-surfaces test-services
```

Pull requests run the same `run --group fast` command. The workflow also offers
an explicit manual native integration qualification job using an official Arch
image pinned by digest. It installs the current native packages and records their
versions; the package repository itself is not a frozen OS snapshot. This job is
not yet a required PR check. Enable that only after confirming the complete suite
on the hosted runner. Both jobs upload diagnostic artifacts even after failure.

Physical hardware, real login, and manual release signoffs remain separate from
unattended tests. A successful integration run is not full release approval.

## Maintaining the runner

Register suites in `scripts/test-suites.json`; record helper and historical-file
exclusions in `scripts/test-exclusions.json`. Each entry declares capabilities,
build flags, working directory, fixture variant, timeout, output shape, and source
files. Update shared diagnostics/preparation in `scripts/test_environment.py` when
adding a dependency. No suite should depend on a developer's absolute checkout.

Run `python3 scripts/test.py check-registry` to compare the registry with actual
Zig target listings, including optional feature modes, and the Python inventory.
The `--python-only` variant needs no Zig installation. Run the behavioral runner
tests with `python3 -m unittest discover -s tests -p test_runner.py -v`.
