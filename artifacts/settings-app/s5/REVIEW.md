# S5 — Package and integrate

Status: implemented, validated and approved by the user; S6 authorized.
Date: September 15, 2026.

The application, CLI dispatch and flyout integration are **Zig**. Python is used
for private-session tests and existing release tooling.

## Delivered

- The default build and staging installer include `pearl-settings`, its desktop
  entry, matching scalable icon and AppStream metadata. Stable and Git package
  paths include the fourth executable. Git installs use `pearl-settings-git`
  and `org.aqueous.Pearl.Git.Settings`; stable installs retain
  `org.aqueous.Pearl.Settings` and the existing desktop categories.
- `pearlctl settings show` opens Overview. Shared `--page` routes and Aqueous
  `--section` destinations select the existing application window. Both
  `pearlctl aqueous show --section SECTION` and legacy `--text SECTION` work.
  Invalid destinations and outputs are rejected before changing visible state.
- Each compact page has **Open full settings** with its current destination.
  Native activation context restores a minimized application. Successful dispatch
  releases popup keyboard input; missing or invalid executables leave a usable
  flyout and feedback. An absent installation has a disabled action and explanation.
  Bar primary actions and keyboard mode `none` retain the approved flyout behavior.
- The verified backend starts only its fixed sibling executable with validated
  argv. Direct `posix_spawn` reports execution errors synchronously, closes
  inherited service descriptors and avoids GLib's shell fallback for invalid
  executable formats. GDK supplies activation context; GLib reaps child processes.
  The frontend remains open when the backend exits.
- Release manifests, reproducibility hashes and gates require all four binaries
  and the Settings payload. Release validation includes the standalone suites and
  checks that staged launch evidence matches the packaged production binaries.
- README and Preferences, Aqueous Settings, Desktop, Surfaces, frontend API and
  release documentation describe launching, Apply scope and backend/draft lifetime.

The handoff initially occupied a fixed footer. Large-text tests on short outputs
found that it consumed too much height. It now lives in the selected page's scroll
area while the section header remains fixed. Page changes retain one handoff
widget without retaining hidden service bodies or their interests.

## Validation

All Zig builds used `-Doptimize=ReleaseSafe`. Integration used private compositor
sessions, D-Bus services and temporary installation roots. No host installation,
service activation or package publication was performed.

| Check | Result |
| --- | --- |
| Pure tests | 107 passed |
| Release tooling tests | 5 passed |
| `test-settings-integration` | 8 groups passed |
| `test-release` staged install and migration | 2 groups passed |
| `test-preferences` retained compact editor | 24 groups passed |
| `test-dock-islands` | 17 groups passed |
| `test-settings-lifecycle` | 10 groups passed |
| `test-aqueous-settings` / `test-aqueous-preview` | 22 / 3 groups passed |
| `test-settings-accessibility --full-matrix` | 8 groups, 35 configurations and 175 page checks passed |
| Default production build and installed resource paths | Passed |
| AppStream validation, shell/Python syntax, Zig formatting | Passed |
| Source/documentation diff whitespace | Passed |

The S5 suite launches the actual production desktop entry using launcher keyboard
input, pins its matching desktop ID, verifies a normal minimizable/maximizable
window, and checks stable/Git package identity. Instrumented binaries expose
read-only route/state information for exact CLI and handoff assertions. Handoff
uses actual GTK keyboard input. Tests cover repeated activation, every shared
route, invalid destinations, missing/removed/invalid binaries, backend exit and
the actual Git `package()` function. Paths containing spaces are included.

[Machine-readable reports](validation.json) include retained report paths and
binary hashes. The staged install, final production build and launch suite hashes
match for Pearl, pearlctl and pearl-settings.

### Metadata compatibility note

[AppStream validation](appstream-validation.txt) succeeds with two pedantic notes.
[desktop-file-validate](integration/desktop-validation.txt) reports only the three
existing supported desktop names `Aqueous`, `Aqueous-Git` and `Aqueous-Intel-Git`
as unregistered `OnlyShowIn` values. The filter intentionally matches the supported
session environment; the test rejects any other diagnostic. Actual GIO launcher
discovery and production application launch pass.

## Screenshots

- [Installed production application launched from the menu](integration/session/desktop-launched-settings.png)
- [Missing executable keeps the flyout available with feedback](integration/session/handoff-missing-retains-flyout.png)

## Approval boundary and remaining acceptance

S6 requires separate approval, as requested by the user. It owns final full-window
visual comparison, physical-monitor/input/assistive-technology acceptance, and
migration of legacy popup-only master UI acceptance to the normal application.
The full release gate and publication have not been run or declared complete.
Existing release licensing/manual signoff requirements remain in effect.

`{launched:true}` confirms successful executable dispatch. Frontend initialization
and verified-session checks still run in the new process; this response does not
promise that a process cannot fail later or that configuration was saved.
