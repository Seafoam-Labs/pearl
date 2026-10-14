# Desktop icon implementation evidence

The implementation is in `src/desktop/icons/`, with wallpaper ownership in the
surface manager and draft controls in Settings → Appearance. New installations
enable icons; existing documents and explicit choices retain their behavior.

## Automated checks

- `zig build test -Doptimize=ReleaseSafe`: 292 tests passed; see [build.log](build.log).
- `test_desktop_icons.py`: see [verification.json](verification.json) for the
  final private-session result, individual checks and large-directory metrics.
- `test_surfaces.py`: [33 checks passed](surfaces.json), covering surface/input, hotplug, reservation, blur and
  default/Vulkan renderer regressions.
- `zig build test-desktop -Doptimize=ReleaseSafe`: production shell build and [15 checks passed](production-desktop.json), covering
  discovery, launch, controls and latency checks passed.
- `test_preferences.py`: [25 checks passed](preferences.json), including generation cancellation, atomic
  saves, concurrent edits and recovery. The generator fixture explicitly starts
  as an established installation so first-install setup does not affect its
  generator invocation count.
- The new desktop Appearance controls passed native input, shared-draft and
  Discard checks. The full `test_settings_appearance.py` suite did **not** pass:
  fatal GTK rendering warnings occurred during lock/unlock on one run and after
  applying the existing theme form on another (`gdk_frame_timings_throttling_hint`
  and `Trying to snapshot GtkGizmo … without a current allocation`). Their cause
  has not been established; no warning was suppressed to obtain a passing result.
  The [harness failure](settings-appearance-failure.log) and
  [GTK warning](settings-rendering-warning.log) are retained.

Run the dedicated suite through `python3 scripts/test.py run --suite
test-desktop-icons` or `zig build test-desktop-icons`. For direct runs:

```sh
zig build build-desktop-icons-test -Doptimize=ReleaseSafe
python3 tests/integration/test_desktop_icons.py \
  --pearl zig-out/bin/pearl-integration --ctl zig-out/bin/pearlctl \
  --output .cache/desktop-icons-final
```

The harness isolates HOME, Desktop, state, configuration, D-Bus and compositor
sockets. Launch tests use a marker-writing fixture. The directory stress metric
includes creating files and waiting for their enumeration, and RSS measures the
whole instrumented shell; these are local observations, not performance budgets.

## Captures and remaining validation

The [desktop](desktop.png), [context menu](desktop-context-menu.png),
[approval prompt](desktop-launcher-approval.png) and
[Settings draft](settings-draft.png) are actual private-session captures. The original
[mockups](../../docs/mockups/desktop-icons/README.md) remain design references.
Additional captures cover [light](desktop-light.png), [dark](desktop-dark.png)
and [native GTK with enlarged text](desktop-gtk.png).

Manual screen-reader announcements, physical-display fractional scale/rotation,
all desktop bar/dock geometries, adversarial replacement races and exhaustive
permission-failure injection still need release qualification. Cross-display
placement, external drag-and-drop, clipboard transfers, special volume icons
and thumbnails remain outside the initial scope.
