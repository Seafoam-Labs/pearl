# Bar editor concept

Open [index.html](index.html) directly in a browser. This self-contained
HTML/CSS/JavaScript mockup shows the proposed menu system inside Pearl Settings'
**Bar & dock** page. It uses local vector icons and sample data; no installation,
network connection or running Pearl session is required.

The [implementation plan](../../BAR_EDITOR_IMPLEMENTATION_PLAN.md) covers native
GTK integration, shared drafts, plugin compatibility and acceptance criteria.
The [native implementation evidence](../../../artifacts/bar-editor/README.md)
contains actual Settings screenshots and test results.

## Try the design

- Choose **Add widget** in Left, Center or Right. Search, change the destination,
  then select a widget. Already placed widgets are listed separately.
- Open a widget's **•••** menu to move it earlier/later, move it to another
  group, or remove it. Launcher is required but movable.
- Open **Launcher → Change icon…** to choose a bundled icon, enter a theme
  name, preview a local PNG, or reset. Apply/Discard include the artwork choice.
  The browser uses placeholders for installed theme names; native Pearl validates
  static PNGs and offers Retry for missing files.
- Change the edge to Left or Right to see Top / Center / Bottom labels. Change
  the bar size or Separate islands toggle to update the schematic preview.
- **Apply & save** updates only the demo's in-memory baseline. **Discard**
  restores that baseline. Reloading restores the original sample.
- Try Light preview and a narrow window. Group cards stack, the content scrolls
  within the application, and the footer remains visible. Sections opens the
  compact sidebar.
- Use Tab/Enter for buttons and Escape to cancel a picker or action dialog.

The search field filters choices. Launcher icon names are optional text input. The Focus timer plugin is illustrative. Other sidebar destinations link
to the plan, and the reduced Dock/Flyouts sections demonstrate retained settings
rather than a complete implementation of those pages.

## Captures

| View | Image |
| --- | --- |
| Settings page with ordered groups | [Desktop](desktop.png) |
| Add widget menu | [Picker](add-widget.png) |
| Widget move/order/remove menu | [Actions](widget-actions.png) |
| Light appearance | [Light](light.png) |
| Stacked groups and compact navigation | [Narrow](narrow.png) |

Direct states: `?menu=add`, `?menu=actions`, `?theme=light`.

## Verification and limits

Local Chromium/Playwright checks cover initial values, search and addition,
duplicate prevention, cross-group moves, ordering boundaries, empty groups,
required Launcher behavior, removal, Apply/Discard, exact size, vertical labels,
islands, dialog keyboard focus, sample plugin selection, light appearance and
390/560-pixel widths. No JavaScript errors or horizontal document overflow were
observed. See [verification.json](verification.json).

These are mockup checks. Native implementation and validation are recorded
separately in the implementation evidence linked above. The mockup does not
implement backend validation, byte/plugin-count limits, discovery, output
overrides or recovery states. The preview is a
schematic, not a pixel-exact rendering of the desktop bar. The mockup has no
access to user preferences or services.
