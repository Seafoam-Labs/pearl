# Issue #3: preferred launcher fix

Implemented in Pearl on 2026-09-24 with the existing Aqueous protocol.

Both dock and global tasks now use one resolver: explicit launcher choice, unique
matching pin, unique matching user-local entry, then unique system match. A
matching custom pin keeps its windows in one dock group. Catalog/pin edits
invalidate stale running-group launch and pin actions. Desktop IDs containing
spaces and Unicode are accepted consistently, with bounded UTF-8/path validation.

## Native evidence

- [Preferred launchers](preferred.json): 12 cases cover custom SVG and themed PNG
  icons, automatic native pinning and relaunch, arguments and desktop actions,
  duplicate candidates, pin/catalog changes with an open menu, and spaces/Unicode
  across restarts. The no-identity-link case explicitly asserts the retained
  limitation; it is not counted as automatic origin detection.
- [Manual choices](manual.json): all 13 existing checks pass with a custom desktop
  ID containing spaces and Unicode, including native picker search/selection,
  correction of an old packaged pin, missing/hidden entries, restart and outputs.
- [Dock](dock.json), [running applications](running-apps.json),
  [GIO desktop](desktop.json), [preferences](preferences.json), and
  [Settings editor](settings.json) regressions pass.
- [Same-ID baseline](same-id.json) verifies PNG live addition, in-place editing,
  atomic replacement, removal and startup overrides on the production binary.
  Its final two distinct-ID observations retain the documented manual-choice
  requirement; their expected packaged result is not evidence of a fix.

The ReleaseSafe production build and all 193 pure unit tests pass. Reports retain
binary hashes. These are private native Wayland sessions with synthetic desktop
entries, not qualification of the reporter's unidentified application. XWayland
matching policy has unit coverage; this run does not establish native XWayland
presentation acceptance.

[Automatic custom group](custom-wmclass-unpinned-native-pin.png) and
[Unicode desktop ID after restart](desktop-id-restart-1.png) are native captures.
[Launch records](launches.jsonl) preserve the fixture's desktop-file path and
actual arguments.

## Reproduction and limits

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-preferred-launchers -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-desktop-overrides -Doptimize=ReleaseSafe
```

The new preferred-launcher runner replaces the investigation runner. Baseline
observations remain under [reinvestigation](../reinvestigation/README.md).

An existing wrong packaged pin is preserved until **Use launcher…** corrects it.
An unrelated desktop ID without a matching StartupWMClass still needs that choice.
Multiple profiles reporting the same identity use the same preferred launcher;
this implementation does not infer which process launch created each window.

Two existing regression harness assumptions were corrected: restarted desktop
search waits for initial preferences to finish applying, and preference editing
reopens its popup after a bar-layout change dismisses it. The themed-icon fixture
uses installed icon themes as its fallback instead of an incomplete hicolor index.
