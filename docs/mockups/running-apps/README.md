# Running applications concept

Open [index.html](index.html) directly in a browser. This self-contained mockup
shows a proposed global application widget in the desktop bar and the existing
selection-based **Bar & dock** page in Pearl Settings. No server, dependencies,
network access or running Pearl session is needed.

The [implementation plan](../../RUNNING_APPLICATIONS_BAR_WIDGET_PLAN.md) covers
the native model, widget, popup, settings integration and acceptance tests.
The [native implementation evidence](../../../artifacts/running-apps/README.md)
contains actual Pearl screenshots and verification results.

## Try it

- Click **Web browser** to choose between three windows on workspaces 1, 2 and
  4, including an External display window. Selecting one updates the sample
  active workspace/display and focused application.
- Click **Files** to activate its single window. Click **Terminal** to restore
  its minimized window on workspace 4. Secondary-click any application to open
  its chooser, including single-window applications.
- Change the sample to **Many applications**. The overflow button opens all
  remaining application groups; choose a group, then its window. Narrow the
  browser to see more groups move into overflow.
- Select **No open applications** to see the runtime widget collapse while
  its Settings entry remains available.
- In Settings, use **⋯** to move/reorder/remove Running applications. The
  schematic preview updates immediately; **Apply & save** updates the demo's
  saved bar placement. **Discard** restores the last saved layout.
- Remove the widget, then choose **Add widget** in any group to add it back.
  The picker prevents a duplicate when it is already placed.
- Try **Light preview**, Tab, arrow keys inside dialogs, Enter and Escape.
  The browser prototype allows keyboard focus on its buttons. Native Pearl
  will keep the bar unfocusable and expose the chooser through a separate
  popup/CLI entry point, as specified in the plan.

## Captures

| View | Screenshot |
| --- | --- |
| Desktop bar and Settings placement | [Desktop](desktop.png) |
| App chooser spanning workspaces/displays | [Window chooser](window-chooser.png) |
| Additional application groups | [Overflow](overflow.png) |
| Adding the widget after removal | [Add widget](add-widget.png) |
| Light appearance | [Light](light.png) |
| Narrow Settings and compact bar | [Narrow](narrow.png) |

Direct states: `?menu=windows`, `?scenario=many&menu=overflow`,
`?menu=add`, `?theme=light`. The Add state shows the widget as already added;
remove it through its actions menu to make it selectable.

## Verification and limits

[verification.json](verification.json) records local Chromium/Playwright checks
for grouping, remote-workspace activation, minimized restoration, overflow
reachability, placement, reordering, Apply/Discard, removal/addition, duplicate
prevention, empty state, dialog focus and 390/560/850-pixel layouts. Screenshots
were visually reviewed. All application and window state is simulated.

The mockup focuses on top-edge layout. Native vertical bars, output geometry,
live window churn, compositor focus, localization, screen-reader integration
and shared preference validation are covered separately by the native
implementation evidence and its documented limits.
The runtime bar is schematic; the Settings preview shows exact sample order,
while the desktop strip demonstrates group placement. Other existing widget
choices and sidebar destinations are decorative context in this focused demo.
There is no disk persistence, application launch or access to actual windows.
