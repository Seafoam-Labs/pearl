# Bluetooth interface implementation plan

Status: design proposal. The [mockups](mockups/bluetooth/README.md) extend the
implemented [Network interface](NETWORK_UI_IMPLEMENTATION_PLAN.md) to Bluetooth.
This change contains design assets and documentation; the live Bluetooth
interface is unchanged.

Make connected devices easy to identify, paired devices easy to reconnect, and
pairing instructions specific to the step the user must complete. Keep discovery
explicit and device trust separate from pairing.

## Visual design

![Bluetooth Settings and flyout](mockups/bluetooth/desktop.png)

Use the same semantic theme tokens, card treatment, status hierarchy, comfortable
controls and persistent Settings footer as Network. The flyout prefers 408 × 800
logical pixels, clamped to the user's popup limits and output. Both surfaces
have one body scroller. Settings retains its existing sidebar/Sections behavior.

The [pairing board](mockups/bluetooth/states.png) and
[narrow light view](mockups/bluetooth/narrow-light.png) cover prompts, recovery,
device details and responsive rows. Drawn colors are illustrative; production
uses Pearl's theme tokens and supports native GTK styling.

## Existing service contract

[`services/bluetooth.zig`](../src/services/bluetooth.zig) already supplies eight
bounded adapters and 64 devices. Adapters have identity, label, power and
discovery state. Devices have identity, adapter, label, address and separate
Paired, Connected, Trusted and Blocked flags. Existing actions cover power,
discovery/stop, pair, connect/disconnect, trust/untrust and owned cancellation.

The service registers a client-local Agent1 and supports PIN/passkey input,
confirmation, display and authorization prompts. Discovery belongs to one view
and adapter and has a 30-second timer; pairing has a 90-second deadline. Existing
owner, prompt-serial, generation and late-reply safeguards remain authoritative.
See [connectivity behavior](CONNECTIVITY.md#bluez) for cancellation limitations.

The model does not expose battery levels, device categories, RSSI freshness,
audio routing, hardware radio-block reasons or RemoveDevice. Do not invent
those facts or add controls that imply support for them. Generic Bluetooth
icons are appropriate until typed device metadata is available.

## Surface behavior

| Area | Proposed behavior |
| --- | --- |
| Adapter status | Show loading, unavailable, no adapter, off or on. “On” is separate from the count of connected devices on the selected adapter. |
| Power | Accessible switch calls the existing power action for the selected adapter. It is not a new global radio toggle. Disable conflicting changes while an operation is pending. |
| Adapter selector | Visible only with multiple adapters. Use label plus an identity suffix such as `hci0` to distinguish equal labels. Changing selection does not power adapters or start discovery. |
| Connected devices | Show only confirmed Connected devices, with Disconnect and Settings-only Details. Keep independently connected, unpaired devices in this section without claiming they are paired. |
| Paired devices | Show Paired devices that are not connected, with Connect and Details. “Paired” does not imply reachable. Do not duplicate connected entries here. |
| Add a device | Find devices explicitly starts discovery on the selected adapter. Show cached unpaired entries as previously discovered, not confirmed nearby. New rows have Pair. |
| Device details | Show full name, address, adapter, pairing/connection state, blocked state and explicit Trust this device switch. Reflect the actual Trusted property; no implicit trust on pairing. |
| Feedback | Keep the target and action visible while pending. Only the owning view gets Cancel or its prompt. Explain failures without inferring a wrong code from generic denial. |

For duplicate aliases on the selected adapter, show an address suffix in the
row and the full address in Details. Never merge devices by alias or address
alone: use service epoch, adapter path and device path as identity. Keep full
names available to assistive technology and wrap long text.

Settings shows the complete bounded device lists. The flyout shows up to three
connected devices and three paired devices, with a count and “View all devices”
when more are retained. Find devices reveals the discovered-device section
without hiding connected controls; results scroll inside the same body. The
Bluetooth settings action stays outside that scroller. Hide empty connected
and paired sections; show an explanatory empty state under Add a device.

## Discovery and ownership

Opening either view, selecting an adapter or turning it on never initiates a
search. The initiating view shows Starting search, Looking for devices and
Stopping search as distinct states. Stop search releases only Pearl's owned
lease. After the search ends, retain results without claiming current range.
Do not show a countdown without a backend-provided remaining deadline.

Other views may report discovery activity but cannot stop another view's lease.
Adapter.Discovering alone does not establish ownership. Disable adapter
selection during this view's pending pairing or search; let the user cancel or
stop explicitly before changing targets. A removed adapter invalidates selection
and its actions, then selects an available adapter without starting work.

Use the existing acknowledged Settings launch path. Disable handoff while the
flyout owns pairing/connection work or discovery, with “Finish or cancel pairing”
or “Stop search to open Settings”. Do not transfer a conversation or restart
discovery in the new owner. Launch failure retains the flyout and its explanation.
Closing releases only that view's unfinished work; established connections stay.

## Pairing and recovery

Pair invokes Pair, not a new pair-and-connect chain. After confirmation of
Paired, move the entry to Paired devices and offer Connect unless Connected is
independently true. Keep focus with the same device as its section changes.

| Prompt or state | Presentation and action |
| --- | --- |
| Numeric confirmation | Name the device, display the zero-padded code, explain comparison, offer Cancel and Codes match · Pair. |
| PIN or passkey input | Use the actual prompt kind, labeled input and the existing validation/secret-entry policy. Offer Cancel and Pair; do not substitute a default code. |
| Display only | Show the provided code and device instructions, Waiting for the device and Cancel pairing. No approval control. |
| Authorization | Identify the device and any service supplied by the backend; offer Allow and Cancel. |
| Confirmed authentication rejection | Explain rejection, clear the old input and offer a fresh attempt. Never retain a code for automatic retry. |
| Generic failure or timeout | State that pairing/connection failed or timed out; offer Try again and Dismiss. Retry revalidates identity, adapter power and owner. |
| Blocked device | Show Blocked, disable mutations as required by the existing service and explain that it must be unblocked elsewhere. No unsupported Unblock button. |
| Service unavailable | Clear stale connected claims, disable actions and show reconnection status. No adapter is a separate state only after a valid snapshot. |
| Incomplete results | Explain service truncation; do not label a bounded subset as exhaustive. |

Prompts remain inline in the flyout and modal in Settings. Escape first cancels
the owned conversation and restores device focus. Input clears on submit,
cancel, replacement, lock, daemon loss and view destruction. Codes travel only
through the existing owner-scoped prompt channel, never general row snapshots,
diagnostics or persistent settings.

## Native implementation stages

All new application logic and tests where appropriate are Zig. Existing Python
private-service harnesses may be extended for integration validation.

| Stage | Changes | Completion check |
| --- | --- | --- |
| Shared projection | Add `services/bluetooth_presentation.zig` for typed adapter/status/sections/actions and stable keys. Preserve existing service limits. | Pure tests cover independent flags, blocked/powered-off devices, duplicate names, multiple adapters, ownership and daemon loss. |
| Settings contract | Add optional typed `bluetooth` to `settings/live_protocol.zig` and `live_backend.zig`; retain generic rows for older frontends and fallback for older backends. | Whole bounded snapshot fits the frame alongside legacy data in a maximum-size test; otherwise use revision-bound pagination. Prompt challenges remain separate. |
| Shared native view | Add `ui/components/bluetooth.zig` and `settings/bluetooth_view.zig`, integrate through `desktop/connectivity.zig` and `settings/live_view.zig`. Reuse common visual helpers from Network without forcing Bluetooth through its radio/grouping policy. | Retained widgets, selection and prompt input survive unrelated updates; both frontends dispatch existing authorized actions. |
| Details and handoff | Add native device details, explicit trust, contextual accessibility names, compact footer and ownership guards in panels/manager. Update the Settings preview. | Trust changes only on user action; failed launches preserve the flyout; no owner or secret transfer. |
| Validation and docs | Extend private BlueZ fixtures, add a focused Bluetooth UI target, update connectivity/frontend docs and capture actual views. | State matrix, responsive layouts, cancellation, restart and accessibility checks pass with evidence. |

Expose semantic GTK headings, switches and buttons. Name details buttons with
their device context. Target at least 44 logical pixels for controls. Announce
significant connection/prompt changes, not every discovery update. Retain stable
ordering while users interact; do not jump the focused row on every snapshot.
Provide English and German labels and preserve native keyboard navigation.

## Validation plan

Exercise real GTK input against private BlueZ fixtures: power and adapter
selection, no scan on entry, explicit start/stop/expiry, late discovery completion,
all Agent1 prompt kinds, rejection, cancel, trust/untrust, stale generations,
removed devices, independent views, lock, frontend crash and daemon restart.
Verify Pair does not silently imply Connect or Trust and that cancelling cannot
claim to undo a pairing already completed by BlueZ.

Capture dark/light/native themes, 360/440-pixel windows, short flyouts, enlarged
text and 1×/1.5×/2× scaling. Check duplicate aliases, long Unicode names, empty
lists, eight adapters, 64 devices and truncation. Verify full labels, focus
restoration, screen-reader descriptions and reachable footer/actions.

Run `zig build test`, `test-connectivity`, `test-settings-services`,
`test-settings-lifecycle`, `test-settings-presentation`,
`test-settings-accessibility` and `test-settings-integration` in addition to the
new focused target. Reassess the [Network gate limitations](../artifacts/network-ui/README.md)
instead of treating those earlier results as Bluetooth acceptance.

Battery/device-type extensions, removal/unblocking, Bluetooth discoverability,
audio-profile/routing controls and automatic reconnect policy are follow-ups.
