# Bar autohide verification

Implemented opt-in bar autohide with a two-logical-pixel edge sensor, a 450 ms
hide delay, popup/gesture holds, no application-space reservation, live settings
and per-display overrides. Always visible remains the default.

| Verification | Result | Report |
| --- | --- | --- |
| Autohide, surface-test compositor | 21 checks passed, including output removal | [report](report.json) |
| Autohide, newer cached Aqueous | 20 checks passed; output removal excluded | [report](current/report.json) |
| Settings bar editor | 18 checks passed | [report](settings/metadata.json) |
| Preferences | 25 checks passed | [report](preferences/metadata.json) |
| Surface lifecycle, input and blur | 19 checks passed | [report](surfaces/results.json) |
| Dock and islands | 17 checks passed | [report](dock/report.json) |
| Bar layout and opacity | 45 cases passed | [report](layout/metadata.json) |

ReleaseSafe compilation and all 174 pure tests also pass. Integration reports record
binary hashes where supplied by the harness; regression suites were run during
implementation, with the final autohide runs covering the completed controller.
Sessions use private D-Bus and headless Wayland instances with fatal GTK warnings.

Representative captures:

- [Autohide setting](settings/session/bar-autohide-settings.png)
- [Top islands revealed](session/top-True-revealed.png)
- [Right continuous bar revealed](session/right-False-revealed.png)
- [Reveal over a fullscreen application](session/fullscreen-revealed.png)
- [Independent input surface beneath a hidden bar](session/hidden-input-underlay.png)

The newer cached compositor at `.cache/aqueous-activity-production/bin/aqueous`
asserts in `OutputManager.validateConfigCoordinates` when disabling an output.
This was reproduced during testing and is already noted by the repository's
bar-layout harness. The full hotplug check passes against `.cache/aqueous/bin/aqueous`.
The newer-build report explicitly records the excluded check; it does not claim
hotplug validation for that compositor.

Run the complete suite with:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-bar-autohide -Doptimize=ReleaseSafe
```

For the newer cached compositor, add:

```sh
-- --aqueous .cache/aqueous-activity-production/bin/aqueous --skip-hotplug --output artifacts/bar-autohide/current
```

The controller replacement addresses GTK motion controllers retaining their
`contains-pointer` state across unmapping; the controller has no reset override
in [GTK's implementation](https://raw.githubusercontent.com/GNOME/gtk/main/gtk/gtkeventcontrollermotion.c).
Both final runtime runs exercise pointer re-entry following session inhibition.
