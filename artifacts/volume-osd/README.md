# Volume OSD verification

Passed on September 20, 2026: unit tests, service integration (including volume
OSD coverage), and surface/input/CLI-isolation/native-blur regression suites.
GTK integration runs with `G_DEBUG=fatal-warnings`.

The service suite uses a private compositor, D-Bus, PipeWire/Pulse server, and
synthetic audio outputs. No host volume or power settings are changed.

Reproduce from the repository root:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test -Doptimize=ReleaseSafe
zig build test-services -Doptimize=ReleaseSafe -- --output artifacts/volume-osd/services
zig build test-surfaces -Doptimize=ReleaseSafe -- --output artifacts/volume-osd/surfaces
```

[Service results](services/results.json) cover observed external/local changes,
mute, zero, text/card replacement, quiet unchanged events/default switching,
session inactivity, rapid final values, and native lock/input/display lifecycle.
[Surface results](surfaces/results.json) cover focus, click-through input, output
geometry/hotplug, CLI isolation, and native blur/opaque fallback.

Screenshots:

- [Dark](services/services/volume-dark.png), [light](services/services/volume-light.png),
  and [GTK theme](services/services/volume-gtk.png).
- [Muted](services/services/volume-muted.png), [zero](services/services/volume-zero.png),
  and [full](services/services/volume-full.png).
- [Bottom bar clearance](services/services/volume-bottom-bar.png).
- [Long label at fractional scale](services/services/volume-long-label-fractional.png).

The JSON reports include executable hashes. Logs and captures come from isolated
synthetic sessions; they do not establish physical media-key bindings. Existing
bindings must change the audio service for Pearl to observe their result.
