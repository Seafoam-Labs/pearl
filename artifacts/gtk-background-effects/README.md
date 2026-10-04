# GTK background-effect repair — 2026-10-03

The source repair and local package validation pass. ISO construction and the
affected physical live machine remain unvalidated. No service, renderer or
`GDK_WAYLAND_DISABLE` workaround was installed.

The source was based on `25805901726d7ae7000bb8ab8df42ee611954929`. Both runtime
tests use the same binary built against workstation GTK **4.22.5**, package
`1:4.22.5-1.1`. The staged image inspected during this implementation contains
GTK **4.24.1**, package `1:4.24.1-2` (newer than the handoff's 4.24.0 image).
Its GTK and required GLib libraries were copied into `.cache/gtk-4.24/lib` for
client-only runtime selection. The actual process mappings and library hashes
are recorded in each result file. GTK 4.24.0 source was inspected, but its exact
runtime was not executed here.

| Check | GTK 4.22.5 | GTK 4.24.1 |
| --- | --- | --- |
| Full `test-surfaces` suite | Pass, native owner | Pass, GTK owner |
| Visual compositor rule veto/restoration | Pass | Pass |
| Blur capability off/on, custom alpha, resize | Pass | Pass |
| Rounded islands, clear gaps, scaling/rotation | Pass | Pass |
| Popup, dock, notifications, OSD, switcher lifetimes | Pass | Pass |
| Fade clear before unmap, remap restoration | Pass | Pass |
| Default and explicit Vulkan launch | Pass | Pass |
| Rebuilt package's blur suite | Pass | Pass |
| Packaged popup/output destruction and return with blur active | Pass | Pass |

`zig build test -Doptimize=ReleaseSafe` passed all 259 tests. Four synthetic
trace-ledger tests also passed. The full suite's no-blur input/hotplug cases use
the existing default Aqueous fixture; blur cases use the existing
`.cache/aqueous-global-switcher/bin/aqueous` fixture to exercise switcher support.
The suite records the compositor binary hash. An initial run of the pre-repair
binary with the production fixture failed the existing `basic()` output-removal
expectation; the unchanged default fixture passed. This fixture difference is
not presented as a repair result.

The unrepaired cached binary was also run with staged GTK 4.24.1 in private
Vulkan Aqueous. The retained before traces show duplicate requests for the same
live surface and the server's fatal response:

```text
wl_display#1.error(ext_background_effect_manager_v1#53, 0,
                  "surface already has a background effect")
```

The first reproduction used GTK's default renderer and exited with
`VK_ERROR_SURFACE_LOST_KHR`; the retained before server/client trace uses the
suite's Cairo renderer to capture the fatal protocol response explicitly.
After repair, the primary blur trace contains 17 native-owned effects on 4.22.5
and 21 GTK-owned effects on 4.24.1, all destroyed correctly. GTK's extra empty
effects for wallpapers and reveal strips are valid. The ledger checks object
lifetimes and committed regions rather than counting numeric IDs globally.

The screenshots show blur enabled, compositor rule veto, and restoration. Mean
pixel difference in the popup sample is **1.3699009324** under veto and **0.0**
after restoration on both runtimes. The modern request uses CSS `blur(14px)`
(GSK radius 28, above GTK's extraction threshold 20); Aqueous's configured
radius remains 8 with 2 passes. Default/Vulkan launch logs retain the driver's
`VK_SUBOPTIMAL_KHR` resize warnings, which also occur on GTK 4.22.5. Those usable
swapchain warnings are allowed specifically; protocol, CSS and other warnings
still fail the gate.

Reproduce the full runtime pair:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-surfaces -Doptimize=ReleaseSafe -- \
  --effects-aqueous .cache/aqueous-global-switcher/bin/aqueous \
  --output /tmp/pearl-surfaces-422
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-surfaces -Doptimize=ReleaseSafe -- \
  --effects-aqueous .cache/aqueous-global-switcher/bin/aqueous \
  --gtk-library-path .cache/gtk-4.24/lib --output /tmp/pearl-surfaces-424
```

The rebuilt, uninstalled package is
`.cache/background-effect-repair/package/pearl-1:0.2.0-1-x86_64.pkg.tar.zst`.
Its SHA-256 is
`c876c99f1784f624973652db437a8557439899f233e3ff3e8c7c1ffa91db11eb`.
`package-build.json` records `makepkg`, package `check()`, payload validation,
source archive and binary hashes. The package's archived source was compared
against the final repair/test hashes in `validation.json`. Its extracted payload
was tested without installation, using both runtime libraries. This is a local
candidate retaining the existing package version, not a published release.
Build checks, bindings and all package GTK minimums remain at 4.22.5.

The Devario ISO builder requires a signed Pearl package in its complete core
repository closure. The documented unsigned local exception covers six
OS-owned installer packages and excludes Pearl. No signing, publishing, trust
policy changes or ISO rebuild was performed. The affected live machine's VM/SSH
target was requested and is still needed for final release acceptance.

`gtk-422/` and `gtk-424/` contain results, object summaries, compressed Wayland
traces and screenshots. `before-*.log.gz` records the unrepaired failure.
