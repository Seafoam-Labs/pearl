# Display brightness flyout proposal

Open `index.html` directly in a browser. It is self-contained apart from its local
CSS and JavaScript, requires no server or network, and uses simulated displays.
The implementation plan is included below the interactive mockup.

Try selecting each display, adjusting brightness, turning a screen off and
restoring it, collapsing the display list, toggling Night Light, switching
appearance, and choosing the unavailable, failed-update, or disconnected states.
Successful writes simulate a 450 ms delay. Failed writes restore the confirmed
value. Changing target or scenario cancels pending mock operations.

The restore button represents the real input-driven wake path; the mockup does
not turn off the screen hosting it. Values are illustrative percentages, not
measurements of luminance. No system commands, hardware access, or persistence
are performed. Unsupported displays remain unavailable; software dimming is a
separate, optional follow-up.

## Production touchpoints

- `src/services/power.zig`: currently one sysfs backlight and logind brightness;
  introduce a per-display service with asynchronous backlight/DDC backends.
- `src/desktop/panels.zig`: existing quick brightness slider and new display picker.
- `src/desktop/services.zig`, `src/settings/power_view.zig`,
  `src/services/power_presentation.zig`: shared presentation and settings.
- `src/services/brightness_feedback.zig`: per-display confirmed-value tracking
  and OSD feedback, including identity changes.
- `src/cli/protocol.zig`, `src/settings/protocol.zig`: optional explicit target
  fields with a documented default for existing callers.
- `src/platform/wayland/idle.zig`, `src/services/lifecycle.zig`: existing native
  output-power objects, per-output actions, and common idle/manual wake ownership.
- `build.zig` and packaging: optional external-monitor backend and its access rules.

Hardware brightness needs no new Aqueous protocol. Confirm that its output
metadata is sufficient for unambiguous device mapping; add metadata only if
necessary. Harden and test the existing power handler's hard-disabled/destroying
state assumptions during concurrent output changes.

Implement production logic in Zig, following repository policy. HTML/CSS/JS here
are design artifacts, not the production UI. Native and physical-monitor testing
remain separate from prototype validation.

## Preview validation

`verify.py` uses Python's standard library and a running local ChromeDriver.
Set `MOCKUP_WEBDRIVER` and `MOCKUP_BROWSER` to override the driver URL and browser
binary. Run `python3 docs/mockups/display-brightness/verify.py` from the repository
root. It writes screenshots and `verification.json` in this directory.

The recorded run passed 17 checks covering delayed updates, switching targets
during a write, screen-off/restore, unavailable controls, failed writes,
disconnection, collapsing the picker, Night Light, light appearance, narrow
layouts at 390 and 560 pixels, and browser errors. `desktop.png` is the default
preview; other screenshots capture alternate states.
