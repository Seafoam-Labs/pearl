# Pearl greeter

Pearl includes a separate Zig 0.16.0 / GTK4 greeter implementation for greetd,
with generated Ghostty bindings, Material or installed GTK themes, and an installed
Wayland/X11 desktop chooser. **Production activation remains gated.** The host
executable refuses startup until Aqueous provides the verified restricted host
contract described in [AQUEOUS_GREETER_REQUIREMENTS.md](AQUEOUS_GREETER_REQUIREMENTS.md).
The [compatibility record](GREETER_COMPATIBILITY.md) distinguishes private tests
from real greetd/PAM, desktop, hardware and accessibility acceptance.

The greeter shares presentation with `pearl-lock`. Login authentication belongs
to greetd; the existing locker still unlocks an already running Aqueous session.
Other selected desktops own their shells, services and lockers.

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

## Configuration and sessions

Review `packaging/greeter/greeter.json` as the starting configuration. The future
installed path is `/etc/pearl/greeter.json`, root-owned and not group/world writable.
The same restrictions apply to parent directories and discovered session entries;
symlinked entries are rejected. Invalid security-critical config stops startup.
Missing optional session directories are skipped; malformed entries contribute
to `--catalog`'s skipped count. Unavailable executables, TryExec dependencies, X11
adapters and unapproved UWSM profiles remain unavailable in the chooser.

| Setting | Behavior |
| --- | --- |
| `theme` | `material_dark`, `material_light`, or `gtk` |
| `gtk_theme` | Optional trusted installed GTK theme name; otherwise GTK's default |
| `wallpaper` | Optional administrator-owned PNG/JPEG; at most 16 MiB input; current shared decoder restricts dimensions to 4096 per axis and 8 Mi pixels |
| `font_size`, `reduced_motion` | 12–32 px base font and animation policy; larger-text button remains available |
| `preferred_output` | Connector preference for initial card placement; output changes never authorize authentication |
| `roots` | Ordered session directories, each with `path` and `type` (`wayland` or `x11`); earlier entries mask later entries with the same ID |
| `default_session`, `force_session` | Preferred ID, or administrator-enforced ID |
| `allow`, `deny` | Optional lists of session IDs; deny wins |
| `remember_session` | Opt-in accepted selection memory per username; defaults off |
| `allow_uwsm` | Defaults false; enable only after validating every exposed managed profile, using `allow` to constrain the catalog |
| `x11` | Defaults false; enabling also requires startx and the packaged X11 adapter, plus distribution/VM verification |
| `accounts`, `power`, `screen_reader` | Optional AccountsService labels, permitted logind controls and fixed Orca launcher |
| `auth_timeout_seconds` | 30–300 seconds; transport/cancellation and handoff deadlines are separately bounded |

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
Aqueous's restricted input API. Orca launching is optional; private AT-SPI access,
speech and credential privacy still need explicit real accessibility acceptance.
Power controls honor logind capability and require confirmation. They never ask
for interactive privilege escalation or install permissive polkit rules.

## Appearance export

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
It does not create system users, change PAM, enable services or replace
`/etc/greetd/config.toml`. The shipped release gate explicitly remains false.
Ordinary Pearl installs do not depend on a display manager. Aqueous is required as
the eventual greeter host; other desktops are installed separately as desired.
The package does not overwrite another desktop's session entry.

Before deployment, complete GR01 and the full real-desktop VM matrix, match the
installed greetd package to its source/patches, reproduce release artifacts in two
fresh roots, settle license ownership and obtain the physical/Orca signoffs. A
build or nested UI pass cannot override these gates.

A future activation procedure must first back up `/etc/greetd`, record the current
`display-manager.service` target and enabled units, keep a working console login,
and snapshot the VM. Review the greeter account/home/config ownership and the
selected VT. Only then install the reviewed config, create the account/state paths
and change display-manager activation. For rollback, stop/disable greetd from the
retained console, restore the backed-up configuration and previous display-manager
unit, and reboot the guest. Distribution-specific activation/rollback commands
must be verified in that guest before they are offered for host execution.
