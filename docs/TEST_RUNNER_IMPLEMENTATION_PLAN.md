# Self service test runner implementation plan

Status: implemented, with native platform and optional-suite qualification still
in progress. `scripts/test.py` is the shared local and fast-CI entry point; see
[TESTING.md](TESTING.md) for the shipped interface and current limits. The native
CI job is manually selectable until its hosted-runner qualification is complete.
The stages below retain the design and acceptance criteria.

A contributor should be able to discover the available tests, diagnose missing
dependencies, prepare private fixtures, run a chosen suite, and locate actionable
failure evidence without knowing the original developer's filesystem or asking
an assistant. Existing Zig targets and Python test assertions remain the execution
engine; the new runner owns setup, selection, reporting, and cleanup.

## Current behavior and gaps

- [build.zig](../build.zig) exposes individual tests and aggregate targets.
  `zig build integration` runs lifecycle tests, not every integration test.
  Python files under `tests/integration/` include executable harnesses and shared
  helpers; indiscriminate unittest discovery does not run this collection.
- [release-validate.py](../scripts/release-validate.py) runs a fixed regression
  matrix and records exit codes, but does not cover every current test. It forces
  one Aqueous prefix and does not provide prerequisite discovery or preparation.
- [build-aqueous-master.py](../scripts/build-aqueous-master.py) builds pinned
  compositor/helper binaries and patched wlroots. Its default source checkout is
  developer-specific. Diagnostic and bootstrap builds are separate variants.
- [pearl_session.py](../scripts/pearl_session.py) already creates private sessions,
  configuration roots, buses, and child processes. Its provenance metadata contains
  absolute library paths, which matter when relocating a cached build.
- [t00.py](../scripts/t00.py) supports `PEARL_TEST_AQUEOUS_SOURCE` for input
  fixtures, but some callers supply explicit cache paths. Setting one environment
  variable does not eliminate every path assumption.
- The [PR workflow](../.github/workflows/ci.yml) runs model/Unicode, clock,
  release-tooling, and protocol-trace tests. It does not run desktop integrations.

## Scope and support

Deliver native x86_64 Linux support first, with a verified Arch-based development
environment for desktop integrations. Keep the existing Ubuntu-compatible fast
tests available. Other distributions receive capability checks and exact missing
versions, without claiming support until their clean setup has been verified.

Cover all existing Pearl test entry points through an audited registry. Optional
Qt, plugin, upstream, long-running, and bundled-application tests are explicit
groups. Physical displays, real login, fingerprint hardware, and manual release
signoffs remain documented acceptance procedures outside unattended execution.

The runner may download and build dependencies in its workspace cache when the
user invokes `prepare`. It does not install system packages, change PAM/greetd
configuration, activate services, or install Pearl into the running desktop.
Print the distribution-specific package commands for the user to execute.

## Command interface

Implement `python3 scripts/test.py` using Python 3.12 or newer and only the standard
library for the runner itself. Suite prerequisites may require a newer interpreter.
Resolve the repository from the script location, not the caller's
working directory. No arguments prints concise help and the first-run commands.

| Command | Contract |
| --- | --- |
| `list` | Show groups, suite IDs, descriptions, prerequisites, and coverage relationships without building or downloading. Support JSON output. |
| `doctor --group integration` | Check the selected group's toolchain, libraries, Python imports, fixture state, and runtime capabilities; show every discovered problem and its next action. |
| `prepare --group integration` | Fetch verified inputs and build missing private dependencies. Reuse valid prepared artifacts. Stop before building when required system packages are missing. |
| `run --group integration` | Check prerequisites, build Pearl as needed, execute every selected suite, and write results. Never silently prepare or omit unavailable suites. |
| `run --suite test-settings-app` | Build and run a named suite using prepared fixtures. Repeat `--suite` to select several. |
| `run --group integration --dry-run` | Show resolved suites, commands, working directories, build variants, and output locations without execution. |
| `rerun --failed RUN_DIRECTORY` | Create a new run for failed, timed-out, interrupted, or blocked suites from an earlier result. Retain the earlier evidence. |

Require `--group` or `--suite` for selection commands; reject combining them.
Resolve selection once and deduplicate only identical suite, build-option, and
fixture combinations; release and diagnostic variants remain distinct. Add `--output`,
`--fail-fast`, and `--jobs` for output placement, early stopping, and Zig build
parallelism. Execute suites serially initially because several share `zig-out`
and fixture state. Separate checkout directories can run independent CI jobs.

Common fixture overrides are `--aqueous-source` and `--aqueous-prefix`. A source
override is a read-only Git input containing the pinned revision; it never means
"test whatever is currently checked out." Validate an existing prefix against
the required revision, build variant, helper capabilities, and recorded hashes.
Give suite-specific options explicit names and validate them before subprocesses
start; do not forward arbitrary arguments to every Python harness.

The intended first-run experience, after following the documented OS package
setup, is:

```sh
python3 scripts/test.py list
python3 scripts/test.py doctor --group integration
python3 scripts/test.py prepare --group integration
python3 scripts/test.py run --group integration
```

`doctor` may initially report missing managed fixtures and direct the user to
`prepare`. No exported environment variables or existing Aqueous checkout are
required for the default managed setup. An offline setup can supply a local
checkout and a fully populated dependency cache; offline mode must fail clearly
before attempting an unavailable download.

## Suite registry and coverage

Add `scripts/test_suites.py` as the explicit registry. Each suite declares its
stable ID, description, group membership, working directory, command argument
list, build options, fixture variant, prerequisite capabilities, timeout, and
artifact paths. Record whether its output argument expects a directory, a JSON
file, or is unsupported. Keep the registry importable without Zig or native
libraries so discovery and diagnostics work on an unprepared machine.

| Group | Intended coverage |
| --- | --- |
| `fast` | Existing PR checks: `test`, both clock targets, release-tooling tests, and Python protocol-trace tests. |
| `native` | Additional compositor-free adapter, binding, greeter-unit, theme, and tooling checks identified by the inventory. |
| `integration` | Core Pearl lifecycle, desktop, settings, service, security, capture, and theme sessions using the pinned Aqueous stack. Includes core Vulkan-dependent cases. |
| `greeter` | Private greeter protocol, process, UI, appearance, and mock authentication suites. |
| `qt` | Qt consumers and sessions, with matching QtEngine/Darkly prerequisites. |
| `plugins` | Plugin host, discovery, UI, and activity suites with pinned SDKs, example components, and diagnostic compositor variants. |
| `upstream` | Explicit pinned Aqueous and upstream PAM regressions. |
| `apps` | Phyto, Dome, and Coral tests, with namespaced IDs and their own working directories. |
| `extended` | Long-running performance and soak checks, with distinct timeouts and reporting. |
| `release-regression` | Preserve the current release runner's exact required target set and release build options. Passing this group alone is not release approval. |
| `all` | Union of registered unattended groups, with duplicates removed. Every selected prerequisite is required. |

During inventory, assign every executable test a registry entry or an explicit
exclusion with a reason. Distinguish shared helper files, historical harnesses,
manual procedures, aliases, and targets that already execute other tests.
Document aggregate coverage so invoking a broad target does not accidentally
repeat its constituent suites. Do not infer requirements from filenames: some
integration-directory tests only need a compiled CLI and temporary files.

Add a registry consistency check against build target listings and executable
test files. Account for targets generated by loops and feature flags in
`build.zig`; a regex over literal `b.step` calls is insufficient. Fail this check
when a new executable test has neither a mapping nor an explained exclusion.

## Dependency checks and preparation

1. Read Zig and Aqueous pins from `.zigversion`, `build.zig.zon`, and
   `scripts/aqueous-target.json`; reject conflicting declarations. Extend the
   Aqueous target configuration with a verified upstream source URL. Verify that
   a clean fetch can obtain the exact commit; never substitute the latest branch.
2. Check selected capabilities only: compiler/build tools, pkg-config versions,
   `glib-compile-resources`, Python/Pillow/PyGObject imports, GI typelibs, fonts,
   Wayland protocol XML, D-Bus tools, capture tools, and feature-specific SDKs.
   Print required versus detected versions, affected suites, and corrective
   commands. Validate imports with the same Python interpreter used by fixtures.
3. `prepare` can install a checksum-verified pinned Zig toolchain locally when
   absent and create a managed Python environment. Preserve access to required
   system PyGObject/typelibs; do not assume that an ordinary isolated venv can
   import them. Lock downloadable Python dependencies and record system package
   versions separately. Configure child `python3` lookup consistently.
4. Build the matching Aqueous, aqueousctl, aqueous-config, and patched wlroots
   through the existing build script. Select production, activity diagnostic, or
   bootstrap variants per suite. Build plugin examples and optional fixtures only
   for groups that require them. Keep variants in distinct cache directories.
5. Key prepared state by platform, toolchain, Aqueous revision, patch/input hashes,
   build options, relevant native-library versions, and preparation-script hash.
   Use completion stamps written only after success; rebuild incomplete or
   incompatible artifacts. Lock shared preparation state against concurrent writes.
6. Centralize source/prefix resolution in shared helpers. Set both
   `PEARL_TEST_AQUEOUS_PREFIX` and `PEARL_TEST_AQUEOUS_SOURCE`, then replace explicit
   developer/cache paths that bypass them. Resolve protocol data through
   pkg-config where possible. Make provenance paths relative to their prefix or
   rebuild relocated artifacts instead of trusting stale absolute paths.
7. Probe the selected compositor in a short private headless session. Check actual
   rendering/capture capability, not only whether `vulkaninfo` exists. Distinguish
   a headless backend from a software renderer: headless alone does not prove a
   GPU-free setup. Use the pinned revision's build policy, not current upstream
   behavior, to determine allowed renderers. Report software Vulkan support only
   after a working smoke test; never replace required Vulkan coverage with Pixman.

Network access is expected during preparation and Zig dependency fetching.
Prefetch the selected dependency graph for an explicit offline run and verify it
without network access. Tests using private local HTTP/TLS fixtures retain those
fixtures; a group must declare any genuine external-service dependency.

## Execution and results

Reuse the existing build graph rather than duplicating executable build commands.
Use subprocess argument arrays and explicit working directories. Keep private
HOME/XDG, display, bus, PAM, and service fixtures in the existing session harness.
Tests must not attach to the user's live desktop as a fallback.

Acquire a checkout execution lock before mutating shared build outputs. Stream
bounded live progress and preserve complete per-suite logs on disk. Print the
current suite, elapsed time, result, and output path. Continue independent suites
after a failure by default; mark dependents blocked with the original cause.

Handle timeouts, SIGINT, and SIGTERM with partial-report persistence and bounded
cleanup. Audit child processes that create their own sessions: killing the Zig
parent alone will not necessarily stop a compositor or private bus. Extend shared
process ownership tracking as needed, give harnesses a chance to run `finally`,
and force termination only for recorded processes belonging to the run.

Store each run under `.cache/test-runs/<unique-id>/` by default. An explicit output
directory must not overwrite prior evidence. Write atomic `results.json`, a short
human-readable summary, per-suite logs, and links to screenshots/native reports.
Include a schema version, selected and excluded coverage, actual command/options,
timestamps, durations, exit codes, dependency versions, fixture provenance, and
source fingerprints. Hash relevant source, tests, fixtures, resources, scripts,
manifests, and selected subprojects; a Git commit alone misses local edits.

Statuses are `passed`, `failed`, `timed-out`, `blocked`, `interrupted`, and
`not-run`. Selected suites missing prerequisites make the run incomplete and
nonzero; no success-on-skip mode. Exit codes: 0 when every selected suite passed,
1 for suite failures/timeouts, 2 for invalid usage or missing prerequisites, 3 for
runner infrastructure errors, 130 for interruption. If failure and blockage coexist,
return 1 and preserve both statuses in the report.

`rerun` also includes selected suites left `not-run` by an early stop. It produces
fresh evidence with a link to its parent run and rechecks current
inputs and labels changed source/dependency fingerprints; it never combines old
passes and new failures into a claim that the current tree passed the whole group.
JUnit output may report each suite as a test case where no finer structured result
exists; do not invent individual assertion counts from arbitrary log lines.

## Implementation stages

### 1 Inventory and command contract

Add the registry, `list`, selection validation, and `--dry-run`. Audit root and
subproject build targets and Python entry points, including optional build modes.
Define the native package profiles and verified Aqueous source location.

Exit criterion: every current executable test has a mapping or explained exclusion;
commands can be inspected on a machine with only the supported Python interpreter.

### 2 Prerequisites and fixture preparation

Implement `doctor`, `prepare`, managed toolchain/dependency state, and shared
Aqueous path resolution. Reuse existing builders and add capability smoke tests.
Document the first supported OS package setup and Python environment strategy.

Exit criterion: an empty-cache checkout prepares the core integration environment
using only the documented commands; a second preparation reuses valid outputs.
Missing packages and unavailable pins produce specific next actions.

### 3 Execution and evidence

Implement `run`, result persistence, suite adapters, bounded cleanup, and `rerun`.
Integrate fast, native, and core desktop suites first. Add explicit mappings and
preparation for greeter, Qt, plugins, upstream, apps, and extended groups before
claiming complete `all` coverage.

Exit criterion: every shipped group reports exact selection and deterministic
failure semantics; interruption leaves a useful report and no owned processes.

### 4 Release compatibility and CI

Move release matrix selection to the shared registry. Keep
`scripts/release-validate.py` as a compatibility adapter while its callers migrate.
Preserve `--targets`, `--output`, and prior evidence, but enforce fingerprint
consistency before retaining results across `--resume` runs. Continue emitting the
legacy functional metadata expected by `scripts/release-gate.py`; test that partial
runs and incompatible resumed evidence cannot satisfy the release gate.

Switch the existing PR job to `run --group fast`. Add integration jobs using the
same `doctor`, `prepare`, and `run` commands after clean-run qualification. Pin the
native environment, cache verified dependencies, and retain results on failure.
CI matrix jobs must name explicit suite selections and report their combined
coverage; no workflow-specific test selection logic or hidden fallback skips.

Exit criterion: local and CI execution resolve identical suites and build options
for the same group. Required integration coverage is demonstrated on the actual
runner before making it a required PR check.

### 5 Documentation and clean setup acceptance

Add `docs/TESTING.md` with first-run installation, the four-command workflow,
individual-suite selection, artifact examples, reruns, offline preparation,
supported platforms, and common troubleshooting. Link it from README and
DEVELOPMENT; replace stale claims about nonexistent CI or a universal integration
target. Keep manual release gates and optional feature instructions clearly linked.

Exit criterion: a contributor unfamiliar with the harness can run the documented
core integrations in a fresh environment without developer caches, environment
variables, path edits, or assistant intervention.

## Verification and completion criteria

- Exercise real CLI contracts with small fixture executables: missing tools,
  conflicting pins, unknown suites, timeout, nonzero exit, and interrupted runs.
- Verify descendant cleanup with a fixture that launches a detached grandchild;
  ensure an unrelated sentinel process survives. Check concurrent-run locking.
- Verify cache invalidation after changed pins/options/scripts, incomplete builds,
  and relocation. Verify downloaded input checksums and failure recovery.
- Run from a different working directory and an ASCII path containing spaces.
  Detect the documented non-ASCII Zig path limitation early with a clear remedy.
- Validate provenance and rerun behavior with dirty source and changed fixtures.
  Confirm failed or incomplete runs never overwrite previous successful evidence.
- Run fast tests on the existing CI environment, then run core integrations in a
  clean supported Linux environment with no prepared developer state. Retain the
  exact setup commands, versions, and result artifacts as reproduction evidence.
- Qualify optional groups independently, including compositor variants and Qt/plugin
  dependencies. A fake-process orchestration test cannot establish native coverage.
- Check that the legacy release gate still rejects missing suites, stale source,
  and absent manual acceptance. Passing unattended tests must not imply release
  approval or physical hardware qualification.

The implementation is complete when the registry accounts for existing tests,
every delivered group has a verified preparation path, the local guide works from
a clean setup, and CI calls the same runner. Container packaging beyond the first
validated CI environment, additional architectures, and concurrent suites within
one checkout are later improvements rather than prerequisites for this delivery.
