# Launcher calculator validation

Implemented locally on 2026-09-25 for [issue #2](https://github.com/Seafoam-Labs/pearl/issues/2).
See the [implementation plan](../../docs/LAUNCHER_CALCULATOR_IMPLEMENTATION_PLAN.md)
and [calculator help](../../docs/DESKTOP.md#calculator).

## Results

- ReleaseSafe production build passes.
- `zig build test`: **224 tests pass**, including five calculator suites. These
  cover the documented grammar/functions, error domains and resource limits,
  10,000 seeded malformed inputs, and 10,000 finite-value formatting round trips.
- [Calculator native acceptance](latest/report.json): **21 checks pass**. Includes
  real keyboard/pointer activation, independent clipboard paste after dismissal,
  duplicate entries, unavailable-copy recovery, typed and pasted continuation,
  delayed-search races, caret movement, GTK preedit signals, GTK accessible
  label/description properties, two-output job admission, authentication and
  lock cleanup, output power loss, catalog changes/empty catalogs, themes,
  German labels, and compositor loss.
- [Existing launcher regression](regressions/desktop/results.json): **15 checks
  pass**, including GIO desktop actions, Unicode discovery, app/window activation,
  output/workspace identity, 2,000 applications, fractional scales, and teardown.
- [Existing clipboard/capture regression](regressions/clipboard/report.json):
  **15 checks pass**, including selection ownership, transfer limits/timeouts,
  image sanitization, eight output transforms, fractional crops, copy/save,
  authentication/lock privacy, and output lifecycle.

The calculator run measured 12 painted queries: **12.6 ms median, 15.2 ms p95**,
with 2,000 application fixtures. The existing launcher regression measured
**27.3 ms search/paint p95** and **37.6 ms maximum warm opening** across eight
opens. These are private headless-session observations, not hardware guarantees.
Test-only delayed workers are excluded from the calculator timing sample.

The production launcher never exposes expressions through status. The private
instrumented build provides bounded row inspection, worker delays, unavailable
clipboard injection, and GTK preedit signal injection for deterministic tests.
No binaries were installed system-wide and the host desktop was not restarted.

## Captures

- [Material dark](latest/session/calculator-dark.png)
- [Material light](latest/session/calculator-light.png)
- [Native GTK](latest/session/calculator-gtk.png)
- [Larger text](latest/session/calculator-large.png)
- [German labels](latest/session/calculator-german.png)
- [Incomplete expression](latest/session/calculator-incomplete.png)
- [Invalid expression](latest/session/calculator-error.png)

## Reproduce

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-activity-production" \
  ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" \
  zig build test-launcher-calculator -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-desktop -Doptimize=ReleaseSafe \
  -- --output artifacts/launcher-calculator/regressions/desktop
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-clipboard-capture -Doptimize=ReleaseSafe \
  -- --output artifacts/launcher-calculator/regressions/clipboard
```

Native suites require private Wayland/D-Bus sockets, the existing input fixture,
`wtype`, `wl-paste`, `grim`, and the development prerequisites documented in
[DEVELOPMENT.md](../../docs/DEVELOPMENT.md). The calculator suite compiles the
existing output-power fixture with `cc` and `wayland-scanner`.

The calculator suite uses the current pinned Aqueous build. It exercises output
loss through output-power management because the pinned compositor asserts in
its output-management configuration path. The existing regression suites use
their default legacy private compositor. Neither fixture nor Aqueous source was
changed for this feature. Bulky regression captures/fixture payloads are local
under `.cache/launcher-calculator-regressions/`; the reports are retained here.

## Remaining manual qualification

Real screen-reader interaction and a physical IME session remain unqualified.
GTK's accessible properties and preedit suppression were tested programmatically;
that does not establish behavior for every assistive-technology/IME combination.
Locale-dependent number formats, percentages, currency/unit conversion,
arbitrary precision, and full Alfred function compatibility remain outside
this implementation's scope.
