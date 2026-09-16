# Aqueous Displays — simplified setup concept

Open [the interactive mockup](index.html) directly in a browser. It is a
self-contained HTML/CSS/JavaScript file with sample displays, no dependencies,
no external resources, and no access to the compositor or display hardware.

See the [native implementation plan](../../AQUEOUS_DISPLAYS_IMPLEMENTATION_PLAN.md)
for the work required to deliver this design in Settings.

## Design

The page answers three questions in order:

1. **Which screen am I changing?** Numbered screens, an Identify action, and
   matching display selectors connect the arrangement to one selected editor.
2. **How should it look and where should it go?** Resolution, refresh rate,
   scale, orientation, and an **Enable HDR** checkbox sit beside plain-language
   positioning. HDR defaults to automatic settings. Dragging snaps
   screen edges; “To the left of / right of / above / below” and alignment
   controls offer a precise alternative. Coordinates stay under **Exact position**.
3. **When does this take effect?** Edits update an unsaved arrangement. A single
   **Apply changes** action checks the draft and demonstrates a temporary preview.
   **Keep changes** saves the example state. **Revert**, Escape, or timeout
   restores the previous example state while retaining the editable draft.

The Aqueous navigation sublist remains visible. The selected display's controls
replace long repeated sections for every output. **More display options** holds
mirroring, display information, and optional HDR brightness / SDR brightness
adjustments with a **Use automatic settings** reset; profiles, custom modes, and source management
are deferred to a future advanced editor rather than placed in the primary flow.

## Try it

- Drag display 2 to another side, or select it and use the position controls.
- Focus a diagram screen and use arrow keys; Shift moves one desktop pixel.
- Change scale or orientation and watch the arrangement update. Simple edge
  alignment is preserved when the selected screen's dimensions change.
- Check **Enable HDR** on the sample external display to use automatic settings.
  Optional brightness adjustments are hidden under **More display options**. The
  sample laptop display demonstrates the unsupported state.
- Open **Exact position** and edit X/Y. Overlapping extended screens show a
  message and block Apply until separated, or until mirroring is chosen.
- Turn a screen off and back on. The example prevents disabling the last screen.
- Apply a change, then try Keep, Revert, Escape, and the 20-second timeout.
- Switch **Demo state** to **Preview unavailable** to see editing remain
  available while applying is disabled.
- Use **Light preview**, **Reset demo**, or a narrow browser window. Narrow
  layouts stack the editors and keep the action footer visible.

Optional URL parameters: `?theme=light`, `?state=unavailable`, and `?draft=1`.

## Captures

| View | Screenshot |
| --- | --- |
| Default desktop | [Desktop](desktop.png) |
| Unsaved edits | [Draft](unsaved.png) |
| Apply and confirmation | [Keep / Revert](confirm.png) |
| HDR enabled with automatic settings | [HDR](hdr-enabled.png) |
| Optional HDR adjustments | [HDR customization](hdr-custom.png) |
| Light appearance | [Light](light.png) |
| Narrow arrangement | [Narrow](narrow.png) |
| Narrow position controls | [Position](narrow-position.png) |
| Preview unavailable | [Unavailable](unavailable.png) |

## Boundary with production

This is a presentation and interaction proposal, not an implementation of new
hardware capabilities. Names, modes, capabilities, identification, persistence,
and the countdown are illustrative. Reloading the file resets the sample state.

The actual application must continue to use Aqueous's canonical declarations,
capability checks, candidate validation, native preview lease, and authoritative
rollback deadline. The available scenario illustrates that flow when supported;
it does not claim production DRM preview support. See the current
[protected display preview contract](../../AQUEOUS_SETTINGS.md#protected-display-preview).
HDR support must be determined per display and per preview capability. Automatic
HDR settings mean the automatic HDR level and inherited/default SDR brightness;
this should not implicitly enable the separate `auto_hdr` conversion feature.
The mockup’s Automatic option for SDR brightness is a UI choice, not a new literal
value in the numeric backend field.

The Identify action would need real per-output identifiers in production; this
mockup highlights numbers only within the diagram.

If other Aqueous sections have edits, the production confirmation must disclose
those shared-draft changes before applying. This focused example starts with
display edits only. Pearl and Aqueous drafts must remain separate. The reduced
action set is a frontend presentation change: it must not skip validation or
present an unconfirmed or unsupported operation as saved.

## Verification

Seventeen interaction checks passed in local Chromium through Playwright:
selection, field editing, relative alignment, pointer dragging, keyboard movement,
exact-position overlap feedback, enable/disable guards, mirroring, Keep/Revert,
automatic timeout, unavailable preview, Identify/theme, 480/390-pixel layouts,
automatic HDR confirmation, advanced HDR/reset, and per-display HDR availability.
No JavaScript errors or horizontal page overflow were observed. The modal uses
the browser's native dialog focus handling, and Escape reverts the sample
preview. These checks cover the mockup only; see [verification.json](verification.json).
