# Pearl greeter

Pearl includes a separate Zig 0.16.0 / GTK4 greeter implementation for greetd,
with generated Ghostty bindings, Material or installed GTK themes, and an installed
Wayland/X11 desktop chooser. The host uses ordinary Aqueous with its existing
`-c` startup command; no special compositor mode or patched Aqueous build is
required. Real greetd/PAM and desktop handoff acceptance remains pending.
The [compatibility record](GREETER_COMPATIBILITY.md) distinguishes private tests
from real greetd/PAM, desktop, hardware and accessibility acceptance.

The greeter shares presentation with `pearl-lock`. Login authentication belongs
to greetd; the existing locker still unlocks an already running Aqueous session.
Other selected desktops own their shells, services and lockers.

The [fingerprint integration](FINGERPRINT_LOGIN.md) supports automatic passive
scan-message acknowledgement, retained instructions and PAM-controlled password
fallback. Private protocol, GTK, PAM-policy and upstream-module tests are available;
real-reader login remains unaccepted. See its [checklist](FINGERPRINT_LOGIN_IMPLEMENTATION_PLAN.md).

## Build and private verification

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build build-greeter -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-greeter-unit -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-greeter-ipc test-greeter-catalog test-greeter-session test-greeter-services test-greeter-ui test-greeter-host test-greeter-soak -Doptimize=ReleaseSafe
```

`build-greeter` stages production binaries under `zig-out/greeter/bin` and test
binaries under `zig-out/test`. It does not install into the running system or
alter the ordinary Pearl build/install. Test binaries accept private fixture
configuration and socket peers; production binaries do not accept those hooks.
Tests need private Unix sockets and, for UI tests, the repository's private
Aqueous tools. UI screenshots are under `artifacts/greeter/latest/ui/session`.
Never type real credentials into a mock preview.

The production `--catalog` command performs read-only discovery using the fixed
administrator config. `--version` works without a display or configuration. The
private `--probe` mode exercises the real Zig socket client against fake greetd;
it is compiled out of production.

## Arch package installation

The separate [greeter PKGBUILD](../packaging/arch-greeter/PKGBUILD) builds
`pearl-greeter-git` independently of the desktop shell. From
`packaging/arch-greeter`, run `makepkg -si`. Installation creates the default
`/etc/pearl/greeter.json` (UWSM allowed) and replaces `/etc/greetd/config.toml`, provisions
the greeter account/directories, and selects `pearl-greeter.service` for the next
boot without restarting the current desktop. Appearance configuration edits survive
upgrades through pacman's backup handling; install/upgrade hooks reinstall Pearl's
greetd configuration on VT7.

Before installation, `/etc/greetd/config.toml` is copied to
`/etc/greetd/config.toml.bak` if it exists and no backup exists yet. The hook then
replaces the standard config with `/usr/share/pearl-greeter/greetd.toml`.
Both the packaged service and a direct greetd invocation use `/etc/greetd/config.toml`.
The package saves the previous display-manager selection/default target and
restores them on removal unless the administrator has since changed the selection.
It also disables and records enabled `ly.service` and `ly@…service` instances,
which can start independently of `display-manager.service`. If an older install
left Ly enabled, update the package, run
`sudo /usr/lib/pearl/pearl-greeter-setup enable`, then reboot. Rerunning setup
repairs this case while keeping the original restore backup.
Removal also restores the `.bak` when the config still matches Pearl's template.
Run `sudo /usr/lib/pearl/pearl-greeter-setup restore` to restore it earlier.
See [package setup and recovery](../packaging/arch-greeter/README.md) for details.

For startup failures, inspect `journalctl -b -u pearl-greeter.service` and
`coredumpctl info /usr/lib/pearl/pearl-greeter-host`. A GNOME Keyring warning for
the greeter account is not itself evidence of a fatal PAM failure; look for the
process exit or crash that follows it. The host, UI and session launcher initialize
Zig's stderr environment cache before changing environment variables. This fixes
the startup abort caused by Zig 0.16's lazy stderr scan retaining the original
environment array after GLib removes inherited variables.

## Manual setup with greetd

Install the staged production binaries, launchers and runtime dependencies
(Aqueous, dbus-run-session, GTK4 and gtk4-layer-shell). Create the dedicated
`pearl-greeter` account and directories using the packaged sysusers/tmpfiles
examples, and install the example `greeter.json` as `/etc/pearl/greeter.json`,
owned by root. Configure greetd's default session as:

```toml
[general]
source_profile = false

[default_session]
command = "/usr/lib/pearl/pearl-greeter-host"
user = "pearl-greeter"
```

The host requires the runtime directory and `GREETD_SOCK` supplied by the greetd
session. It starts a private session bus and ordinary
`aqueous -no-xwayland -c /usr/lib/pearl/pearl-greeter-init`. The init script starts
`/usr/bin/pearl-greeter`; the host watches its lifetime, stops the compositor when
it exits (including crashes), and reaps descendants before returning to greetd.
Init startup is bounded to 30 seconds and graceful shutdown to 5 seconds before kill.
This lifecycle channel is internal to Pearl; Aqueous needs no greeter API.

`pearl-greeter` itself remains a standalone GTK/layer-shell greetd client and can
be launched by another compositor wrapper that handles compositor teardown.
Use the packaged host for automatic Aqueous startup and cleanup. Configure any
ordinary Aqueous preferences for the dedicated greeter account separately from
the authenticated desktop. This host does not claim to restrict Aqueous actions,
keybindings, capture or IPC; see [host behavior](AQUEOUS_GREETER_REQUIREMENTS.md).

## Configuration and sessions

Review `packaging/greeter/greeter.json` as the starting configuration. The
installed path is `/etc/pearl/greeter.json`, root-owned and not group/world writable.
The same restrictions apply to parent directories and discovered session entries;
symlinked entries are rejected. Invalid security-critical config stops startup.
Missing optional session directories are skipped; malformed entries contribute
to `--catalog`'s skipped count. Unavailable executables, TryExec dependencies, X11
adapters and explicitly disabled UWSM profiles remain unavailable in the chooser.

| Setting | Behavior |
| --- | --- |
| `theme` | `material_dark`, `material_light`, or `gtk` |
| `gtk_theme` | Optional trusted installed GTK theme name; otherwise GTK's default |
| `wallpaper` | Optional administrator-owned PNG/JPEG; at most 16 MiB input; current shared decoder restricts dimensions to 4096 per axis and 8 Mi pixels |
| `wallpaper_fit` | `cover` (default) or `contain` |
| `wallpaper_color` | Optional `#RRGGBB` solid background, also visible around a contained image; null retains the theme gradient |
| `font_size`, `reduced_motion` | 12–32 px base font and animation policy; larger-text button remains available |
| `preferred_output` | Connector preference for initial card placement; output changes never authorize authentication |
| `roots` | Ordered session directories, each with `path` and `type` (`wayland` or `x11`); earlier entries mask later entries with the same ID |
| `default_session`, `force_session` | Preferred ID, or administrator-enforced ID |
| `allow`, `deny` | Optional lists of session IDs; deny wins |
| `remember_session` | Opt-in accepted selection memory per username; defaults off |
| `allow_uwsm` | Defaults true; permits UWSM-managed sessions. Set false to disable entries that directly invoke `uwsm`; use `allow` to constrain the catalog |
| `x11` | Defaults false; enabling also requires startx and the packaged X11 adapter, plus distribution/VM verification |
| `accounts`, `power`, `screen_reader` | Optional AccountsService labels, permitted logind controls and fixed Orca launcher |
| `fingerprint_hint` | Optional generic fingerprint guidance; defaults off and does not enable authentication or inspect enrollment |
| `auth_timeout_seconds` | 30–300 seconds for the absolute attempt deadline and input inactivity; transport/cancellation and handoff deadlines are separately bounded |

IDs look like `wayland:gnome.desktop` or `x11:xfce.desktop`; display labels use
localized desktop names and distinguish identical names. Selection memory contains
only username/ID records, never commands, environment or passwords, under
`/var/lib/pearl-greeter/selections.json` with mode 0600. A remembered ID is resolved
against current trusted metadata. Entry or policy changes during authentication
cancel that attempt; the authenticated launcher checks the fingerprint again.
A start acknowledgement records acceptance, not proof that the desktop became ready.

Desktop Exec lines are parsed into argv, not evaluated as shell text. A fixed
post-authentication helper is the only command submitted to greetd. Selection ID,
fingerprint and desktop identity travel as bounded non-secret environment values.
The helper preserves PAM user/runtime identity, clears pre-login display/bus and
loader values, and resolves the authenticated user's canonical runtime bus where
present. Packaged desktop launchers remain responsible for their own startup and
systemd environment finalization. No Pearl service starts for a non-Pearl entry.

X11 uses the reviewed `pearl-greeter-x11` startx adapter. The X client revalidates
its desktop entry inside the new user X session. This code path is not evidence
of successful Xorg authorization, seat ownership or logout; those remain required
VM cases. Likewise, installed desktop metadata is not a compatibility certificate.
Unsupported Terminal/Path requirements and malformed Exec forms are rejected;
desktop-specific wrapper requirements need pinned validation before deployment.

The footer offers larger text, high contrast and reduced motion for the current
greeter session. Reduced motion also disables GTK cursor/widget animation,
keeping the idle login screen quiet on software rendering. The screen displays
the actual GTK keyboard layout. Changing layouts is gated on
a supported compositor input integration. Orca launching is optional; private AT-SPI access,
speech and credential privacy still need explicit real accessibility acceptance.
Power controls honor logind capability and require confirmation. They never ask
for interactive privilege escalation or install permissive polkit rules.

## Sync appearance from Settings

In **Appearance → Login screen**, select **Sync to greeter**. The same button is
available in the Pearl settings flyout. It copies the background and theme currently
shown in the controls, including an unapplied draft, without applying that draft to
the desktop. Administrator authentication is required. The new appearance takes
effect the next time the greeter starts.

The action is implemented in Zig in both frontends and the packaged
`pearl-greeter-sync` helper. Settings reads and decodes the user's image before
authorization, resizes it to fit 3840×2160, and sends PNG bytes. The helper writes
root-owned assets under `/etc/pearl/greeter-assets` and atomically updates only the
appearance fields in `/etc/pearl/greeter.json`. Session choices, UWSM, authentication
and other login settings are preserved. Solid color, gradient, cover and contain
background modes are supported; returning to solid or gradient clears the old
wallpaper reference.

GTK themes must be installed system-wide; personal theme directories are not
copied. Dynamic themes use the selected static Material light/dark variant.
The button is disabled when the greeter helper is absent. The greeter package
includes the helper, polkit dependency and authorization policy.

Private verification: `zig build test-greeter-sync test-greeter-sync-ui
-Doptimize=ReleaseSafe`. The writer test checks configuration preservation and
invalid input; the UI test drives both buttons, wallpaper resizing and authorization
cancellation without changing the host configuration.

## Manual appearance export

```sh
python3 scripts/export-greeter-appearance.py \
  --preferences /path/to/pearl/preferences.json --output /tmp/pearl-greeter-appearance
```

This exports only appearance fields and an explicitly selected local wallpaper to
a new review bundle. It never installs globally. Dynamic user themes export a
static Material variant; no user generator or configuration script runs before login.
Review/merge the JSON into the administrator configuration and stage referenced
assets at the documented system path only during a later authorized deployment.

## Optional package and deployment gate

```sh
python3 packaging/greeter/stage.py --dest /tmp/pearl-greeter-package
```

Validate packaging with `python3 tests/test_greeter_package.py`. Reproduce stripped
binaries with `python3 scripts/greeter-reproduce.py`.

The destination must be new. The payload contains only production binaries,
trusted launchers, a Pearl desktop entry, documentation and configuration examples.
The staging command does not create system users, change PAM, enable services or replace
`/etc/greetd/config.toml`. The shipped release gate explicitly remains false.
Ordinary Pearl installs do not depend on a display manager. Aqueous is required as
the packaged greeter host; other desktops are installed separately as desired.
The package does not overwrite another desktop's session entry.

Before marking a release accepted, complete the real-greetd lifecycle and
real-desktop VM matrix, match the installed greetd package to its source/patches, reproduce release artifacts in two
fresh roots, settle license ownership and obtain the physical/Orca signoffs. A
build or nested UI pass cannot override these gates.

For activation, first back up `/etc/greetd`, record the current
`display-manager.service` target and enabled units, keep a working console login,
and snapshot the VM. Review the greeter account/home/config ownership and the
selected VT. Only then install the reviewed config, create the account/state paths
and change display-manager activation. For rollback, stop/disable greetd from the
retained console, restore the backed-up configuration and previous display-manager
unit, and reboot the guest. Distribution-specific activation/rollback commands
must be verified in that guest before they are offered for host execution.
