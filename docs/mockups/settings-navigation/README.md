# Settings navigation mockups

Open [index.html](index.html) in a browser. It is a self-contained HTML/CSS/JS
prototype with inline vector icons, no remote resources and no service access.
The [standalone application plan](../../STANDALONE_SETTINGS_APPLICATION_PLAN.md)
describes the pictured window, full page inventory, process/backend boundary,
packaging and acceptance criteria. The separate
[flyout navigation plan](../../SETTINGS_NAVIGATION_PLAN.md) covers compact bar
destinations. These images illustrate the standalone app.

## Review

- Click Sound, Network, Bluetooth or Battery in the example bar. The matching
  page and sidebar selection change together; a repeated click keeps it open.
- Use the sidebar to switch pages. Overview and five detailed page mockups work;
  the other sidebar links open their specification in the plan.
- Edit Appearance, visit another page and use **Preference draft · Review** to
  return. The sample draft survives navigation; Discard restores previous values.
  Apply marks the sample saved without writing preferences.
- Choose **Light preview**, or resize below 760 pixels to try **Sections**.
- Direct URLs support `#sound`, `#network`, `#bluetooth`, `#power`, `#appearance`
  and `#overview`; `?theme=light` previews light styling. `?draft=1#appearance`
  exposes the unsaved footer for design review.

Device names, networks, charging state and volumes are illustrative. Service
actions show preview feedback. This prototype does not implement GTK, native
window activation, credentials, discovery or the production draft engine.

## Static captures and verification

The seven PNG files are browser-rendered captures of this prototype. Desktop
captures use a 1440 × 1040 viewport; the narrow capture uses 560 × 1050.

Verified with a local isolated Chromium/Playwright session: all four icon routes,
same-icon repeat clicks, compact navigation, draft retention across pages,
discard, no narrow-layout horizontal overflow and no JavaScript runtime errors.
These checks validate the mockup only. Production verification is specified in
the plan and has not been run for this documentation change.
