# Issue #3 — launcher choice fix and reproduction

The 2026-09-24 [Pearl-only preferred-launcher fix](preferred-fix/README.md) adds
automatic preference for matching custom pins/user launchers and accepts desktop
IDs containing spaces/Unicode. The evidence below records the earlier manual
selection implementation and baseline reproduction.

Reproduced the reported icon and pinned-launch symptoms on 2026-09-19 **when the
custom desktop file has a different ID and the running window still reports the
packaged application's ID**. The reporter's exact desktop files have not yet
been supplied, so this is a confirmed triggering case, not confirmation of
their precise setup.

Same-ID user overrides worked in every attempted baseline case. The baseline
was captured before runtime changes; the implementation below addresses the
confirmed distinct-ID case through an explicit launcher choice.

## Implemented fix

Open a running application's dock menu and choose **Use launcher…**. Search for
its custom entry and select **Use launcher**. Pearl remembers that desktop ID
for windows of the application, updates an existing source pin atomically, and
uses the same icon/name in the dock and Running applications widget. An unpinned
choice remains unpinned until **Pin to dock** is selected.

Use **Reset to automatic**, or Settings → Bar & dock → Application launchers →
**Remove choice**, to return to automatic matching. Settings removals follow
Apply/Discard. Reset retains explicit pins. Missing or hidden chosen entries
remain unavailable; they never silently fall back to the packaged command.

### Verification

| Check | Evidence |
| --- | --- |
| ReleaseSafe build and 161 unit tests | [Validation](validation.json), [unit output](unit-tests.txt) |
| Same-ID overrides on the final production build | [Override regression](regressions/same-id/results.json) |
| 13 native launcher-choice acceptance checks | [Focused results](fix/results.json) |
| Dock grouping, menus, visibility and persistence regressions | [Dock results](regressions/dock/report.json) |
| GIO discovery/launch, desktop actions, field codes and launcher regressions | [Desktop results](regressions/desktop/results.json) |
| Global running applications and chooser regressions | [Running-app results](regressions/running-apps/metadata.json) |
| Preference persistence, external edits, draft merge and theme regressions | [Preference results](regressions/preferences/metadata.json) |
| Settings launcher removal, Apply/Discard, retained pins and bar editor | [Settings results](settings/metadata.json) |

The focused suite uses real GTK input, a private compositor and buses, a shared
app ID with different packaged/custom launchers, native icon pixel assertions,
and exact launch path/argument records. It covers correcting a packaged pin,
choosing before pinning, duplicate pins, base/new-window/desktop-action launches,
restart, reset, stale picker/menu callbacks, hidden/removed/reinstalled entries,
inactive-session dismissal, two outputs and large text on a small display.

[Custom running icon](fix/session/custom-running.png),
[custom relaunch](fix/session/custom-relaunched.png), and
[the scrollable picker at 640×480 with large text](fix/session/launcher-picker.png)
show actual native rendering. Launches are retained in
[the fixture log](fix/session/launches.jsonl). GTK warnings are fatal in these
private suites.

Run the focused check with:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-desktop-overrides -Doptimize=ReleaseSafe
```

The new association, matching and preference-merge unit tests also pass.
Automatic recovery of the launcher that originally started a window is outside
this implementation: selection is explicit and applies to every window with the
same identity. Wayland was exercised end to end; the XWayland class policy has
unit coverage, with native XWayland presentation still unqualified.

## Baseline reproduction results

The [machine-readable results](reproduction/results.json) contain eight completed
cases. Each records captured dock icon color counts, the launched arguments and
`GIO_LAUNCHED_DESKTOP_FILE`, plus an independent fresh GIO resolution. The fixture
uses red for the packaged icon, green for the user icon, and blue for an edit.

| Case | Observed icon and launch |
| --- | --- |
| Two system roots, no override | First system root's red icon and arguments |
| Same-ID override added while Pearl runs | User green icon and arguments |
| Override atomically replaced | Edited blue icon and arguments |
| Override edited in place; Open new window menu action | Updated green icon and arguments |
| Override removed | Packaged red icon and arguments restored |
| Override present when Pearl starts; pin retained across restart | User green icon and arguments |
| Differently named launcher; pin its running window | Packaged red icon, packaged desktop ID saved, packaged arguments on relaunch |
| Explicitly pin the differently named launcher by its own ID | Custom green icon and custom arguments when launching the idle pin |

`launch_matches` and `icon_matches` in the report compare against the expected
observation for each case, including the reproduced packaged-launch behavior.
They do not mean that the reported issue has been fixed.

## Confirmed sequence

1. Install synthetic `org.pearl.Override.desktop` in the private system data
   directory, with a red icon and `--mark system` arguments.
2. Install `CustomOverride.desktop` in the private user applications directory,
   with a green icon and `--mark renamed` arguments. It has no `StartupWMClass`.
3. Launch the custom entry using GIO. Its actual window app ID is still
   `org.pearl.Override`; the launch log confirms the custom desktop file and
   arguments were used initially.
4. The dock associates this window with `org.pearl.Override.desktop`. Its
   [native context-menu capture](reproduction/session/renamed-running-context-menu.png)
   shows the red icon and **Special system** action alongside the running
   **Override renamed** window.
5. Select **Pin to dock** using the keyboard. The saved pin is
   `org.pearl.Override.desktop`, recorded as `renamed_running_pin.saved_pins`.
6. Close the window and activate the pin. The log records `--mark system`,
   `system two words`, and the packaged desktop-file path.

The relevant path is `task_model.matches` → `task_apps.match` → `Dock.update`
and its group's desktop ID → **Pin to dock** → `Dock.act` resolving that saved
ID through GIO. Matching uses the compositor's app ID/class and desktop ID or
`StartupWMClass`; it does not retain the original launcher identity in this
case. GIO correctly resolves the ID Pearl asks it to launch.

This evidence supports investigating launcher/window association and pin
selection for distinct desktop IDs. It does not support replacing GIO's XDG
precedence logic. Using the packaged desktop ID for a true override worked;
explicitly pinning the custom ID also launched the intended entry, although
running-window grouping for that explicit pin was not checked here.

## Reproduction

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
python3 tests/integration/reproduce_desktop_overrides.py
```

The driver creates private HOME/XDG roots, a headless two-output Aqueous session,
private buses and synthetic session services, and uses real keyboard dock
actions. It needs the same dependencies as `test-dock-islands`, including the
existing local Aqueous input-fixture source. It must be allowed to create local
sockets. Temporary desktop entries and processes are removed on exit; copies,
screenshots and logs remain in `reproduction/session/`.

Baseline: repository `a68bacbb6d285a041023ab3e2951c8258357566f`, ReleaseSafe
production build, Zig 0.16.0, GTK 4.22.5, GIO 2.88.3, cached T00 Aqueous compositor
with pixman rendering. The result records the Pearl executable's SHA-256.

Scope limits: these runs cover PNG file icons, Wayland app IDs, normal launches
and the **Open new window** action. Theme-name/SVG icons, XWayland, explicit
desktop actions, D-Bus activation and matching duplicate `StartupWMClass`
entries were not exercised. Earlier driver attempts encountered pipe-inheritance
and preference-busy harness errors; the retained final run completed all eight
cases with both comparison fields true.
