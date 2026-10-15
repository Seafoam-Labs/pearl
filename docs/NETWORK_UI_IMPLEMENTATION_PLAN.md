# Network interface implementation plan

Status: implemented October 14, 2026. The [mockups](mockups/network/README.md)
remain design references. Both live surfaces now use a shared native Zig/GTK
interface. [Implementation captures and validation](../artifacts/network-ui/README.md)
record the running result and remaining regression-test limitations.

## Implementation notes

- `services/network_presentation.zig` projects typed status, grouped APs, saved
  profile matches and action availability. `ui/components/network.zig` retains
  the shared widgets; `settings/network_view.zig` is the Settings integration.
- Settings receives an optional complete bounded projection alongside the old
  generic page. It does not need to stitch multiple revisions together. The
  maximum-size fixture reserves 160 KiB for the projection within the existing
  256 KiB frame. Legacy pagination remains available to older frontends.
- Both views preserve the existing service leases, generation validation and
  SecretAgent flow. Saved-profile metadata adds no secret reads. A bounded
  non-secret action queue handles the Settings client's busy startup slot.
- Refresh is explicit. Without validated scan-completion evidence, an absent
  saved network says “Saved connection”, not “Not in range”. Backend errors
  remain factual; generic failures are not relabeled as password failures.
- The flyout prefers 408 × 800 logical pixels, clamped to user limits and the
  output. Its Network heading replaces the larger session header, with a Close
  control and persistent Settings action. Section navigation wraps whole words.
- The implementation uses semantic theme colors, English/German labels,
  accessible action names, retained focus targets and responsive row actions.
  Advanced editing remains in `nm-connection-editor`.

All five delivery stages below are implemented. Focused network and service
regressions have been exercised; the broader Settings gates have the documented
compositor, focus and packaging limitations. Those gates are not claimed green.

Make the network flyout useful for answering “Am I connected?” and “How do I join
this network?” Give Network settings distinct sections for Wi-Fi, Ethernet,
saved connections and advanced configuration. Keep both surfaces consistent in
their wording, connection state and available actions.

## Visual proposal

![Proposed Network settings and flyout](mockups/network/desktop.png)

The proposal retains Pearl's rounded surfaces, purple selection color and
existing Settings navigation. The flyout foregrounds the current connection,
then nearby networks. Settings adds room for management without hiding everyday
actions inside an adapter list. Colors in the drawings are illustrative;
production must use Pearl's semantic theme tokens.

See [authentication and recovery](mockups/network/states.png) and
[narrow light settings](mockups/network/narrow-light.png) for additional states.
All network names and connection states are sample data. These are static
vector mockups, with PNG previews, rather than a working prototype.

## Starting implementation (before this change)

| Area | Existing behavior and design consequence |
| --- | --- |
| [Compact controls](../src/desktop/connectivity.zig) | One expanded list combines adapters, APs and saved profiles. It displays signal percentages and security enum names, with connection actions on each row. Separate these roles and make the connected network unmistakable. |
| [Settings backend](../src/settings/live_backend.zig) | The network branch emits generic rows, including `Adapter · state {d}` and security enum names. Its summary omits distinct captive-portal and limited-connectivity messages. Share presentation policy with the flyout. |
| [Settings renderer](../src/settings/live_view.zig) | Generic row/control rendering and a separate authentication dialog support multiple services. Add a network-specific presentation without changing Bluetooth, Sound or other pages. |
| [Network service](../src/services/network.zig) | Already provides device state, active AP, raw SSID, strength, security, saved profiles, radio state, connectivity and owned activation. Saved profiles currently expose a label and compatible device but no raw SSID or connection UUID. Extend the model before merging saved profiles with APs. |
| [Live protocol](../src/settings/live_protocol.zig) | Network actions already cover scan, connect, connect saved, disconnect, enable, disable and cancel. Generic controls do not include a boolean switch or grouped network presentation. Add a typed network snapshot and render the radio switch in the dedicated view. |

The styled Network sample in `src/settings/window.zig` is a preview route.
Updating that sample alone would leave the real service-backed page unchanged.

## Flyout behavior

Use a preferred width of about 408 logical pixels, clamped to the available
output. Preserve the shell's existing section navigation and keyboard routing;
the mockup focuses on the Network body. Keep one body scroller and a persistent
Network settings action at the bottom, clear of the scrolled content.

1. Show overall connectivity directly below the heading. Use a status icon and
   text, with separate radio state below it.
2. Show Wi-Fi with an accessible On/Off switch. The current Wi-Fi connection has
   a named card, a Connected label, signal description and Disconnect action.
   An active wired connection gets its own compact row, including when Wi-Fi is off.
3. Show nearby networks immediately, without the current all-purpose expander.
   Each row has its name, signal/security description and a labeled Connect or
   Set up action. Omit the active network from this list. Initially show up to
   three groups; show “View all nearby networks” when more exist. This opens the
   existing Network settings route, where the full nearby list is visible.
4. Refresh explicitly scans the selected Wi-Fi adapter. Opening either surface,
   enabling Wi-Fi or navigating back never initiates a scan. During the request,
   retain visible rows and change the control to “Refreshing…”. Honor the
   existing cooldown and use a disabled explanation when it applies.
5. When multiple Wi-Fi adapters exist, show a labeled adapter selector. Hide it
   for a single adapter. Use interface names to distinguish equal device labels.
   Selecting an adapter changes the displayed nearby networks, not radio power.
   The Wi-Fi switch retains the service's global wireless-radio semantics.

Network settings uses the established launch/acknowledgement path. A launch
failure keeps the flyout visible with a useful error. During an owned connection
attempt, disable this handoff with “Finish or cancel this connection first”;
do not silently transfer a password conversation between owners. Closing the
flyout still cancels its unfinished attempt under the existing ownership rules.

## Settings page behavior

Use the existing Network route and responsive Settings shell. The page contains
the following ordered sections, with one page scroller and no nested list scroll.

| Section | Contents and behavior |
| --- | --- |
| Connection status | Overall internet state with actionable explanation when needed. This is independent of Wi-Fi power and is not attributed to a particular interface unless the backend can establish that fact. |
| Wi-Fi | Radio switch, optional adapter selector, active network and Disconnect. No active network displays “Not connected”; no adapter displays “No Wi-Fi adapter found”. |
| Nearby networks | Refresh, grouped network rows and connection feedback. Full bounded list is reachable; local filtering may be added for more than eight groups, with “No matching networks” distinct from no scan results. |
| Ethernet | One row per present wired device, a friendly state and interface name. Disconnect when connected, Connect when a supported compatible saved profile is unambiguous, otherwise Set up in the external editor. Do not call every disconnected adapter “Cable unplugged”; that requires carrier evidence not currently modeled. Hide the section when no wired device exists. |
| Saved networks | A collapsed section containing saved profiles, expanded on demand without a new scan. Use Connected, Available or Not in range only when identity and compatibility are known. Otherwise use “Saved connection” with an explanation of unavailable activation. Preserve multiple profiles with the same SSID. |
| Advanced network settings | One explicit external-editor action, described as “VPN, hidden networks, IP & DNS”. Hidden-network creation, enterprise authentication, VPN setup, profile deletion and autoconnect editing remain in that editor for this release. |

Saved rows may connect using the existing saved-profile action when permitted.
Do not introduce an inline Forget or automatic-connect switch until dedicated,
validated service mutations exist. A saved network is not automatically proof
that it is currently reachable. When multiple profiles match, let the user
choose a profile rather than silently changing its security or storage policy.

At narrow widths, replace the sidebar with the existing Sections navigation.
Allow descriptions and names to wrap; move actions below labels when the row
cannot fit. There is no new fixed minimum width. The light mockup depicts a
440-pixel window; test down to 360 logical pixels and with enlarged text.

## Connection and recovery flows

Selecting Connect uses the current generation and concrete target identity.
An open network is labeled “Open network”; a supported secured network invokes
the existing SecretAgent flow. Enterprise, WEP and other unsupported security
use “Set up…” and the installed network editor. Never treat unsupported security
as open or infer an authentication failure from a generic connection error.

In the flyout, replace the selected network's detail area with a stable inline
password form. In Settings, retain an owned modal authentication dialog and
style its content to match the same form. Both name the selected network, use
PasswordEntry with the existing hidden-password policy, and provide Cancel and
Connect. Explain that a newly created network is saved after successful connection;
existing profiles retain their current storage policy. Do not add an unchecked
“remember password” option that the backend cannot honor.

Enter submits a valid entry. Cancel/Escape closes the prompt and cancels only
the initiating owner's attempt. Restore focus to the original action when its
target still exists. Clear secrets on submit, cancel, replacement, navigation,
lock and daemon loss. Never retain a password for automatic retry.

| State | Visible message and action |
| --- | --- |
| Initial loading | “Loading network connections…”; no stale success state or enabled mutation controls. |
| Full internet connectivity | “Internet available”. A green indicator supplements the text. |
| Portal | “Sign-in required” and “Open your browser to sign in to this network.” Preserve connection/disconnect controls. A one-click portal URL launch is deferred until a trusted URL contract exists. |
| Limited | “Limited connection” and “Connected to a network, but internet access may be restricted.” |
| Unknown connectivity | “Internet status unknown”; still show independently confirmed connection and radio states. |
| No internet | “No internet connection”; a locally connected network may still be shown as connected. |
| Wi-Fi off | “Wi-Fi is turned off. Turn it on to find nearby networks.” Retain independent Ethernet status. |
| Hardware blocked | “Wi-Fi is blocked by hardware. Use your device’s wireless switch to enable it.” Disable and explain the radio switch. |
| No nearby results | “No networks found. Move closer to your router, then Refresh.” On first entry without known results, prefer “Refresh to look for nearby networks.” |
| Connecting | “Connecting to Studio…” on the target; show Cancel only to its owner. Disable conflicting mutations. Other owners see a neutral in-progress state without the prompt or cancellation authority. |
| Connection failed | “Couldn’t connect to Studio. Try again or check the network settings.” Try again revalidates the target and starts a fresh operation; Dismiss clears only the presentation message. |
| Confirmed rejected credentials | “The password wasn’t accepted. Try again.” A fresh empty prompt appears only from backend authentication evidence. |
| Service unavailable | “Network service unavailable. Waiting for the network service to reconnect.” Clear stale connection claims, disable mutations and recover through the existing service lifecycle. |
| Editor unavailable | “Install Network Connections (nm-connection-editor) to change advanced settings.” Keep the current surface open. |
| Bounded or incomplete data | Explain that only part of the list is available; expose existing pagination or a continuation control. Never show an incomplete result as an exhaustive empty list. |

The current scan request acknowledgement is not proof that a wireless scan has
finished. Do not display “Updated just now” from method success alone. A future
last-scanned timestamp requires a validated scan-completion source. Signal
strength and connectivity are separate facts; strong signal does not imply
internet access.

## Shared model and architecture

All application logic, GTK view code, build changes and unit tests are Zig.
The SVG files are declarative design assets, not an application implementation.

Add a pure `src/services/network_presentation.zig` policy module. It accepts a
bounded service snapshot and produces typed connection status, radio state,
groups, stable keys, action availability and reason codes. Localized wording
belongs in the UI; do not parse formatted English labels to determine behavior.
Use the same policy in compact controls and the standalone backend.

Group nearby APs by adapter identity, original SSID bytes and security. Never
merge on display label alone. Keep hidden/empty SSIDs separate by object path,
and preserve separate security variants of the same name. Choose the active
AP first, otherwise the strongest compatible AP. Sort on explicit refresh or
entry, pin a pending row, and avoid moving focused rows for every signal change.
A representative path must be revalidated before dispatch, with the usual
generation check. Remove stale targets rather than reconnecting to a new identity.

Read non-secret saved-profile identity fields from the existing GetSettings
path: connection UUID/type, raw wireless SSID and security as available. Keep
the present bounds and validate malformed fields. Join compatible profiles to
nearby groups only when sufficient identity exists; label-only matches are
unsafe. New saved-profile metadata must not request or transport credentials.

Extend `src/settings/live_protocol.zig` with an optional typed `network` payload,
including explicit section identity, state enums and existing action parameters.
Update backend serialization, frontend parsing and API compatibility together.
Respect the existing payload limit. The implemented bounded whole projection
replaces the originally proposed pagination for typed groups; it avoids mixing
service revisions and has a maximum-size serialization test. Preserve the
generic paginated row fallback for older clients and backends. Never mix rows
from different service epochs.

Add `src/settings/network_view.zig` and route only the live Network page through
it. Reuse the existing editor/client and owned prompt lifecycle; the frontend
does not connect directly to NetworkManager. Introduce a compact network view
or isolate the network branch in `src/desktop/connectivity.zig`, leaving
Bluetooth's presentation intact. Share formatting and row composition helpers
where practical, while preserving the two transport boundaries.

Keep the existing service as the authority for owner leases, radio readiness,
pending operations and credential cleanup. Stable row widgets should survive
unrelated updates. A network disappearance, daemon restart or changed prompt
serial must invalidate the relevant callbacks and UI state.

## Delivery stages

| Stage | Files and work | Exit criterion |
| --- | --- | --- |
| 1. Presentation policy | New `network_presentation.zig`; bounded saved metadata in `network.zig`; Zig unit tests and the pure-test root. | Fixtures prove correct status precedence, grouping, saved matching, representative selection and stable ordering. |
| 2. Live page contract | `live_protocol.zig`, `live_backend.zig`, `protocol.zig` as needed, client parsing and `SETTINGS_FRONTEND_API.md`. | Real frontend receives typed sections, accurate availability and owned prompts across pagination and restart; compatibility behavior is explicit. |
| 3. Compact interface | Network branch or new view, `panels.zig`, focus tags, theme/layout CSS. | Joining a visible network requires no list expansion; connected state, Refresh, adapter selection, inline auth and acknowledged Settings handoff work with private services. |
| 4. Settings interface | New `network_view.zig`, integration in `window.zig`/`live_view.zig`, matching preview sample and `resources/settings*.css`. | All sections operate against live service data; saved-list, external-editor, narrow-width and keyboard flows work. |
| 5. Validation and documentation | Private connectivity fixtures, UI captures, `CONNECTIVITY.md`, frontend API documentation and accessibility checks. | Required state matrix and ownership regressions pass; screenshots show dark, light, native theme, narrow and enlarged-text layouts. |

Stages 1 and 2 establish the common contract before either surface ships.
Stage 4 should reuse the accepted compact wording and policy rather than
implementing a second state machine. No new network service dependency is
required for the initial design.

## Accessibility and acceptance

Use semantic GTK switches, buttons, headings and grouped lists. Name Connect
and Disconnect controls with their network context for assistive technology.
Expose full network names accessibly even where a compact label must truncate.
Use a visible keyboard focus ring and comfortable targets, preferably at least
44 logical pixels in the shipped UI. Decorative icons are not separate tab
stops. A persistent footer must never obscure the last row or focused control.

Map colors to existing `container`, `high`, `text`, `secondary`, `primary` and
`primary_container` tokens and appropriate status roles. Verify text contrast,
focus contrast and native theme behavior. Announce significant status changes
without announcing every signal-strength fluctuation. Keep focused controls
and typed credentials stable across unrelated refreshes. Include English and
German strings and test long SSIDs, Unicode and safe binary-SSID labels.

Acceptance matrix (see validation evidence for executed coverage and limits):

- Connect to a visible personal network from the flyout without expanding a
  combined adapter list. Show Connecting, then Connected, only from backend state.
- Repeat with saved/open/enterprise networks, multiple APs with one SSID,
  same-name different-security networks and multiple adapters.
- Exercise cancel, wrong password, generic activation failure, removed AP,
  permission denial, scan cooldown, unavailable editor and truncated results.
- Verify wired-only, wireless-only and simultaneous connections, including
  Wi-Fi off or hardware-blocked while Ethernet remains connected.
- Open Settings and flyout simultaneously. One view cannot see, answer or
  cancel another view's password prompt. Closing one preserves established
  connections and the other view's owned operation.
- Navigate, lock, restart NetworkManager, disconnect the frontend and remove
  an output while a prompt or action is pending. Late replies must not revive it.
- Capture 360/440-pixel widths, a short flyout, default and enlarged text,
  1×/1.5×/2× scaling, and dark/light/native themes. No horizontal overflow,
  hidden primary action, focus loss or repeated status announcement is allowed.

Run `zig build test` for the policy changes. For the integrated views run the
existing `zig build test-connectivity`, `test-settings-services`,
`test-settings-lifecycle`, `test-settings-presentation`,
`test-settings-accessibility` and `test-settings-integration` targets with the
new fixtures. The focused `zig build test-network-ui` target additionally tests
the typed projection through actual GTK controls and produces responsive/state
captures. Broader gate failures are recorded with their practical limits in the
evidence index. Do not mutate the developer's live connections to validate the
design.

## Follow-up scope

Inline IP/DNS configuration, a VPN editor, hidden-network creation, enterprise
credentials, hotspot setup, per-adapter radio controls, Forget/autoconnect
mutations and an automatic captive-portal launcher are separate follow-ups.
The initial redesign exposes an honest external-editor path for these tasks.
