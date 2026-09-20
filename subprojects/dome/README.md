# Dome

A standalone Linux system monitor written in **Zig 0.16.0 and GTK4**, with Pearl
styling and Mission Center as its functional reference.

![Native Dome overview](artifacts/native/overview-dark.png)

Dome provides live CPU, memory, disk, network, GPU and sensor pages, searchable
processes, safe process termination, optional systemd service controls and a
compact summary. Sampling, graph duration, colors, columns and units are
configurable. It runs independently of Pearl and Aqueous.

Build with Zig 0.16.0, `pkg-config`, GTK4/GLib development headers and libc:

```sh
cd subprojects/dome
zig build -Doptimize=ReleaseSafe
zig build run -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/dome`. `zig build` also stages the desktop entry,
AppStream metadata and icon under `zig-out/share/`. Use `--prefix PATH` for an
alternate staging directory; `-Dgit-variant=true` builds `dome-git` with the separate
`org.aqueous.Dome.Git` identity. The tested GTK version is 4.22.5; see the
[implementation status and capability limits](docs/IMPLEMENTATION_STATUS.md).

Useful options: `--light`, `--dark`, `--native-theme`, `--compact`, `--page=0..8`,
`--width=N`, `--height=N`, `--dump` (one read-only JSON snapshot), `--version`.
NVIDIA support loads NVML optionally at runtime. Missing GPU metrics or systemd
do not prevent resource and process monitoring.

| Shortcut | Action |
| --- | --- |
| Ctrl+1 / Ctrl+2 | Overview / Processes |
| Alt+1…9 | Navigate pages |
| Ctrl+F | Search active table, or open Processes |
| Ctrl+P / F5 | Pause or resume / request one sample |
| Alt+Enter | Selected details |
| Escape / Ctrl+W | Dismiss transient UI or clear search / close |

Preferences are written atomically to `$XDG_CONFIG_HOME/dome/preferences.ini`
(default `~/.config/dome/preferences.ini`). History and command lines are not
persisted. Process actions require an explicit confirmation and never elevate
privileges. Group controls require selecting an individual raw process.

Native verification uses Pearl's existing private Aqueous session harness:

```sh
zig build integration -Doptimize=ReleaseSafe
zig build benchmark -Doptimize=ReleaseSafe
python3 tests/soak.py --binary zig-out/bin/dome --seconds 1800
```

The integration harness needs the prepared `.cache/aqueous-activity-production`
prefix, `wtype`, `wlr-randr`, `grim`, D-Bus and Python GObject bindings. An alternate
prefix is accepted through `zig build integration -- --aqueous-prefix PATH`.
Tests create their own display, configuration and service manager fixture; process
actions target only disposable children. They do not alter host services.

Browse the [native screenshots and results](artifacts/native/README.md),
[implementation report](docs/IMPLEMENTATION_STATUS.md), and
[original implementation plan](docs/IMPLEMENTATION_PLAN.md). The earlier
[interactive browser mockup](docs/mockups/index.html) and
[mockup gallery](docs/mockups/README.md) remain available with fictional data.
