# Settings-flyout navigation

Status: implemented and approved, September 15, 2026. This plan covers the bar's compact
settings flyouts. The [standalone Settings application](STANDALONE_SETTINGS_APPLICATION_PLAN.md)
has its own implementation plan and release criteria.

## Implementation review checkpoints

- **F1 complete, reviewed:** shared routes, typed bar target, pure
  navigation transitions and strict optional compact-page parsing are implemented.
  [F1 validation and baseline screenshots](../artifacts/settings-navigation/f1/REVIEW.md).
- **F2 complete, reviewed:** separate service bodies, Overview links,
  fixed header/section chooser and one viewport per page.
  [F2 validation and compact-page screenshots](../artifacts/settings-navigation/f2/REVIEW.md).
- **F3 complete, reviewed:** route-aware popup reuse, explicit CLI
  destinations, page-local scroll/focus restoration and owner-scoped service
  interest, prompts and discovery.
  [F3 validation and compact-page screenshots](../artifacts/settings-navigation/f3/REVIEW.md).
- **F4 complete, reviewed:** service bar routing, accessibility, presentation and
  docs are implemented and verified. The user explicitly chose to retain the
  bar's keyboard mode `none`; no on-demand bar keyboard focus is allowed.
  [F4 validation and screenshots](../artifacts/settings-navigation/f4/REVIEW.md).
- **F5 complete, reviewed and approved:** the navigation acceptance target passed
  all 90 pure tests and eight private integration suites in ReleaseSafe, including
  35 presentation configurations and 175 page checks. Narrow-layout and radio-off
  issues found during acceptance are fixed.
  [F5 validation and final screenshots](../artifacts/settings-navigation/f5/REVIEW.md).

At the current checkpoint `pearlctl control-center show/toggle --page PAGE` selects
the requested compact destination; defaults still select Overview. Internal
navigation restores page-local state, and public `status.popup.page` reports the
selected route. The [service-view ownership contract](SETTINGS_SERVICE_OWNERSHIP.md)
is shared with the standalone plan. Service bar icons now open their matching
compact pages; the gear opens Overview. The standalone handoff remains deferred
until that application's launch contract is implemented.

## Scope split

The original proposal combined direct bar navigation with a full application
window. Those deliverables are now separated:

- **This plan:** service icons open the corresponding page in the existing
  shell-owned flyout, with navigation between compact pages.
- **Standalone app plan:** build the independently launchable `pearl-settings`
  executable and complete sidebar-based application shown in the mockup.
- **Shared contract:** route IDs, category names, validation and service behavior.
  Neither implementation duplicates preference or device-service policy.

The existing [interactive mockup](mockups/settings-navigation/index.html) and
[Appearance image](mockups/settings-navigation/appearance.png) illustrate the
standalone application. They are not specifications for flyout window chrome.
The same category names and direct-navigation behavior apply to both hosts.

## Outcome

Clicking the speaker, network, Bluetooth or battery icon opens the corresponding
compact settings page immediately. Only that page's controls appear in the body.
Users no longer scroll past unrelated session, media or connectivity sections to
reach the control represented by the icon they clicked.

The flyout retains Pearl's existing output anchoring, usable-area limits,
layer-shell focus and dismissal behavior. Its fixed header identifies the current
section and provides a section chooser. Each page owns its own scroll position;
scrolling its body never reveals a different category. The standalone application
is available through an explicit **Open full settings** action when installed.

## Original implementation and cause

The following describes the implementation before F1–F4:

- `src/desktop/bar.zig:201`: audio, battery, network and Bluetooth all construct
  `.pane = .control`; the clicked service is not represented in the event.
- `src/desktop/panels.zig`, `Control.create`: a single scroll container combines
  lifecycle, media, connectivity, sound, power and workspace-layout controls.
- `src/ui/surfaces/manager.zig`, `barAction`: toggling compares pane/output only,
  so distinct service icons are treated as the same destination.
- `showPane` destroys and recreates the popup; current views bind directly to
  shell services and manage service interest through creation/destruction.

Fix the route and page composition. An anchor or scroll-to-card workaround would
still leave every category in one flyout and preserve the ambiguous toggle logic.

## Route and click contract

| Entry point | Compact destination |
| --- | --- |
| Speaker / audio | `sound`: output/input volume, mute and device selection |
| Network / Wi-Fi | `network`: active connection, adapters and nearby/saved networks |
| Bluetooth | `bluetooth`: adapters, paired devices and explicit discovery |
| Battery | `power`: battery, supported profile and brightness |
| Settings gear / control center | `overview`: category links and existing session/layout actions |
| Section chooser | Select the named compact page within the same flyout |
| Open full settings | Launch the standalone app with the selected shared route |

Keep all existing controls reachable through an appropriate compact destination
or a nested section, including application sound streams, media, lifecycle and
workspace-layout controls. The compact Overview links to these existing controls
as well as the four primary pages. It must not require the standalone app to be
installed to retain current control-center capabilities.

Other bar items preserve their existing actions: clock opens the calendar, bell
opens notification history, media opens player controls, tray delegates to its
application, keyboard cycles layout, and launcher/workspaces/overview/capture
retain their functions. Do not turn task controls into generic settings shortcuts.

### Repeated clicks and page changes

1. Validate the destination and originating output before changing the flyout.
2. If closed, open the requested page on that output.
3. If another page is visible on that output, switch directly to the requested
   page. In particular, Sound → Network must select Network rather than dismiss.
4. Clicking the same icon again on the same output toggles its flyout closed,
   preserving existing quick-popup behavior. This differs from the standalone
   app's activation behavior, where repeated launches keep the window visible.
5. A click on another output replaces the flyout there, following current policy.
6. Explicit bar links start at the page heading; internal section navigation
   restores that page's in-session scroll/focus state.

Escape, Close and permitted backdrop clicks still dismiss the flyout. Maintain
one principal popup across outputs. The full Settings window has an independent
lifecycle and is not counted as that popup.

## Shared types and application handoff

Define `src/desktop/settings_navigation.zig` as the single route registry used
by bar events, compact page selection and standalone app launch arguments.
Represent the destination explicitly in `Bar.Event`; retain existing pane events
for actual task popups. App-only destinations can be valid shared routes without
being exposed as compact flyout pages.

Keep `pearlctl control-center show/toggle` compatible, defaulting to compact
Overview, and add a validated optional page argument for compact destinations.
The standalone plan owns `pearl-settings --page`, `pearlctl settings show` and
Aqueous application-launch compatibility. Do not give one command two ambiguous
host meanings.

The handoff launches a fixed installed executable with validated arguments and
available activation context. On success, dismiss the flyout so it releases
exclusive keyboard input. On failure, leave the flyout available and show a useful
error. If the app is not installed, omit or disable the handoff with an explanation;
all current compact controls continue to work.

## Implementation sequence

### F1 — Routes and navigation state

Add the shared route registry and typed bar target. Implement a pure transition
covering closed/open, same/different page and same/different output. Add optional
compact-page parsing in `src/cli/options.zig` and `src/cli/protocol.zig`, preserving
strict field validation and existing default commands. Reject invalid routes
before changing visible state.

### F2 — Separate compact page bodies

Split Sound and Power composition in `src/desktop/services.zig`, and Network and
Bluetooth composition in `src/desktop/connectivity.zig`. Reuse existing service
objects, identities, generation checks, confirmations and error mapping. Compose
Overview from section links and existing actions rather than embedding every
category's form. Preserve a route to every current control-center control.

Give the host a fixed page header/section chooser and a selected page body, using
one stack and one viewport per page. Reuse presentation helpers with the standalone
app where useful; avoid coupling compact layout to its sidebar or window sizing.

### F3 — Integrate popup routing and lifecycle

Update `src/ui/surfaces/manager.zig` to track the selected compact destination in
addition to pane/output. Reuse the flyout host during same-output page changes;
update status/probes to report its route. Keep anchoring, reservations, blur and
modal dismissal intact.

Use explicit page enter/leave/destroy hooks. Enter activates the appropriate
service-view interest; leave disconnects page callbacks and releases that interest.
Stop owned discovery and cancel pending credential/pairing prompts on departure,
clearing secret entries; do not disconnect an established device or network.
Reject stale async callbacks by identity and generation. Do not start scans simply
because the flyout was opened.

When the standalone app is connected simultaneously, service interest and prompts
must be owner-scoped: closing a flyout cannot cancel the app's work. Coordinate
that backend interface with the standalone plan. Lock, output removal and service
loss retain existing denial/cleanup rules.

### F4 — Bar wiring, accessibility and handoff

Wire each of the four icons to its explicit destination and the gear to Overview.
Use accessible labels such as “Open Sound controls” alongside current status.
Announce the selected page and keep hidden controls out of focus traversal.
Support keyboard navigation, large text, dark/light/native GTK themes, reduced
motion and all bar edges. Add the app handoff after its launch contract is available.

Update `docs/DESKTOP.md`, `docs/SURFACES.md`, CLI help and the affected service docs.
No standalone executable, desktop-entry replacement or preference-schema migration
is required to complete this flyout change.

### F5 — Verification and acceptance

Add route/parser/state unit cases and a private-session `test-settings-navigation`
integration target. Exercise actual bar pointer input, flyout keyboard input and
CLI. The user-approved F4 policy keeps the bar's keyboard mode `none`, so direct
bar keyboard focus is intentionally excluded.

| Case | Acceptance |
| --- | --- |
| Four service icons, initially closed | Correct page heading and controls appear immediately |
| Sound → Network → Bluetooth → Power | Page changes in the flyout; no unrelated category in its body |
| Same icon twice | Flyout toggles closed; a different icon switches page instead |
| Different output / all bar edges | Correct target, placement and single-popup behavior |
| Section chooser and internal return | All current controls reachable; page-local scroll/focus restored |
| Unavailable service / no battery / radio off | Correct destination with honest disabled/empty state |
| Scan/pairing prompt → navigate/close/lock | Interest and secrets cleaned up; no stale mutation or leaked callback |
| Concurrent standalone app | Each host releases only its own service interest and prompt |
| Escape/backdrop/output removal | Existing dismissal and input policy preserved |
| CLI defaults, page option, invalid ID | Compatible defaults; bad target rejected without state change |
| App installed / absent / launch failure | Handoff opens matching app page or leaves usable flyout with feedback |
| Narrow/short outputs, 100/125/150/200% scale, large text | Reachable controls and fixed header; no category-spanning scroll |

Run pure tests and the affected desktop, surfaces, services, connectivity and
session-service suites with `-Doptimize=ReleaseSafe` using private fixtures.
Capture actual compact pages on horizontal and vertical bars; keep this evidence
separate from the full-window mockups under `artifacts/settings-navigation/`.

## Completion and dependency boundary

Completion requires the four correct destinations, compact page separation,
retained control-center coverage and passing navigation/lifecycle checks. It does
not require the standalone application to ship first. The optional handoff is
completed when the app is available. The app likewise can ship from its desktop
entry before primary bar navigation changes.
