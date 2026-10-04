# Brightness OSD verification

Passed on October 4, 2026: unit tests, service integration (including the
brightness OSD coverage), and the surfaces regression suite. GTK integration
runs with `G_DEBUG=fatal-warnings`.

The service suite uses a private compositor, D-Bus, PipeWire/Pulse server, and
a synthetic logind/backlight peer. Brightness changes are driven through
direct writes to the fixture backlight's `brightness` file (the same path an
external writer such as `brightnessctl` takes) and through Pearl's own
confirmed `brightness set` requests. No host brightness or power settings are
changed.

Reproduce from the repository root:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test -Doptimize=ReleaseSafe
zig build test-services -Doptimize=ReleaseSafe -- --output artifacts/brightness-osd/services
zig build test-surfaces -Doptimize=ReleaseSafe -- --output artifacts/brightness-osd/surfaces
```

[Service results](services/results.json) cover external sysfs writes popping
the card, surface reuse across refreshes, 1,800 ms expiry, local confirmed
writes replacing the generic text card, denial keeping error text without a
success card, and backlight removal dismissing a visible card.
[Surface results](surfaces/results.json) cover focus, click-through input,
output geometry/hotplug, CLI isolation, and native blur/opaque fallback.

Screenshots:

- [Dark](services/services/brightness-dark.png),
  [light](services/services/brightness-light.png), and
  [fractional scale](services/services/brightness-fractional.png).

The card shows a fixed localized caption, so the long-label bound that applies
to volume device names has no brightness counterpart; the fractional-scale
capture covers layout. The JSON reports include executable hashes. Logs and
captures come from isolated synthetic sessions; they do not establish physical
media-key bindings.
