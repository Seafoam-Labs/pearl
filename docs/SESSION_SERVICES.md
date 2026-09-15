# Notifications, tray and media (T09)

Pearl implements these desktop protocols in Zig 0.16.0 through the pinned
Ghostty GIO/GTK bindings. They use the **session bus**, independently of T07/T08
system services. There is no C bridge, shell command execution or dependency on
DMS/Quickshell. Aqueous remains authoritative for outputs, focus, lock state,
layer placement and background blur.

## UI

The configurable bar gains `notifications`, `media` and `tray`. The notification
button opens grouped history with Do Not Disturb and Clear History. Toasts use a
separate, blurred layer with no keyboard focus or exclusive reservation; their
cards accept pointer input. Up to three fit on the focused output, with fewer on
short outputs. Toasts move to the left while a principal popup is open. Opening
history, media or a tray menu replaces the principal popup. Escape and outside
click retain the existing dismissal behavior.

Media cards appear in their own panel, reached from the media bar item or the
compact Overview's **Media controls** link. Player selection,
previous/next, play/pause, stop, progress and explicit Seek are real controls.
Unsupported controls are disabled. An edited slider position survives focus
moving to Seek; a track change invalidates that edit. Progress is extrapolated
from the player's position/rate and refreshed once per second only while a
media view is open and the player is playing. Closing a view removes its timer;
closing the last media view also cancels artwork work and releases its image.

Tray items render themed icons or ARGB pixmaps, attention/passive state and plain
text tooltips. Left click activates an item (or opens an ItemIsMenu menu), right
click opens its menu and middle click sends SecondaryActivate. Scroll events
are forwarded. At most four icons (two in compact/vertical bars) are shown;
an overflow button exposes the remaining registered items. Menus support nested
navigation, separators, disabled/hidden entries and check/radio toggle state.

## Notification protocol

`org.freedesktop.Notifications` at `/org/freedesktop/Notifications` implements
GetCapabilities, GetServerInformation, Notify and CloseNotification. Advertised
capabilities are exactly `body`, `actions`, and `persistence`. The reported
specification version is 1.2. Body markup, hyperlinks, embedded body images,
image hints, sound and activation tokens are **not advertised**. Bodies are
plain GTK labels: markup is literal text, control characters and bidi overrides
are removed, and truncation preserves UTF-8. App icons accept themed names only.

IDs are nonzero uint32 values, including at wraparound. Replacing an active
notification preserves its ID and atomically replaces content, actions and
expiration. Replacement/CloseNotification only affect records belonging to the
calling unique bus owner. Unknown/closed/foreign IDs return InvalidArgs when
closed. The UI's same-user control endpoint can dismiss or invoke active records.

NotificationClosed is emitted after invalidation with reason **1** for expiry,
**2** for user dismissal or a nonresident action, and **3** for CloseNotification.
ActionInvoked contains the exact registered key; resident actions keep the
notification active. These signals are delivered to the originating client.
The transient hint prevents retention once closed.

An explicit timeout of zero never expires. Positive milliseconds expire on a
one-shot monotonic deadline; the default is five seconds, or persistent for
critical urgency. Toasts disappear after at most eight seconds independently of
protocol lifetime. DND suppresses every urgency's toast but retains eligible
history; turning it off does not replay old deliveries. Lock/disconnection
suppresses presentation, and locked status replies redact summaries. Unlocking
does not replay locked deliveries. Expiration timers continue when necessary to
honor the protocol; history has no polling timer.

History is **in memory for this Pearl process**, not persisted to disk. The 64
record limit includes active notifications and history. Old inactive records
are evicted first; if all slots are active, Notify returns LimitsExceeded.
Clear History preserves active records. Groups are ordered by newest delivery
and records within an application group are newest first.

## StatusNotifier and DBusMenu

Pearl implements the widely deployed KDE interface names:
`org.kde.StatusNotifierWatcher` at `/StatusNotifierWatcher` and
`org.kde.StatusNotifierItem` at each registered item path. Watcher methods,
registered-item/host/protocol-version properties and lifecycle signals are
exported through GIO introspection. Item registration accepts a service name or
the caller's object path. Each target resolves to a unique bus owner before
property reads and actions.

Pearl queues for the watcher name without replacing its owner. When another
watcher owns it, Pearl registers as a host, reads the existing item list and
tracks registration/unregistration signals. If that watcher exits, Pearl may
acquire the queued name. Items must register with the new watcher, as usual.
An existing notification daemon likewise retains its name; Pearl reports that
notifications are unavailable until the name becomes available.

Menus use `com.canonical.dbusmenu`: AboutToShow precedes display, GetLayout reads
the nested tree, Event sends `clicked`, and LayoutUpdated or
ItemsPropertiesUpdated invalidates/refetches the selected menu. Clicks require
the captured item generation and current menu revision. Hidden, disabled,
separator, submenu and stale entries cannot be invoked as leaf actions. Item
menu-path changes invalidate old layout callbacks. An item without DBusMenu
falls back to its ContextMenu method.

## MPRIS and artwork

Initial ListNames discovery plus NameOwnerChanged tracks up to eight
`org.mpris.MediaPlayer2.*` names. Root/player GetAll and PropertiesChanged supply
identity, metadata, status, capabilities and timing. Seeked updates position.
Player names and monotonically increasing owner generations are distinct;
owner loss removes the card, invalidates pending replies and chooses an available
fallback if the selected player disappeared. Controls target the captured unique
owner with no auto-activation. SetPosition includes the current track object
path, is bounded by track length and requires CanControl/CanSeek.

Artwork supports **local `file:///` PNG/JPEG files only**. HTTP(S), other URI
schemes, unsupported formats, invalid images and oversized files use the media
icon fallback. Loading does not fetch network resources. One worker at a time
opens with O_NONBLOCK, validates the opened descriptor as a regular file, reads
at most 2 MiB plus an overflow sentinel, validates dimensions, and decodes at
256 × 256 maximum. Requests cancel/coalesce on URL, selected-player, owner,
visibility or bus changes; stale completions cannot replace the current image.

## Limits and lifetime

| Resource | Limit |
| --- | --- |
| Outbound session-bus calls | 64 in flight; 3-second method timeout |
| Notification request | 64 KiB; 64 retained records; 8 unique action pairs |
| Notification text | app 160, summary 256, body 2048, action key 96/label 160 UTF-8 bytes |
| Toasts | 3 maximum, reduced for short outputs; 8-second presentation maximum |
| Tray items / property reply | 32 / 1 MiB |
| Tray pixmaps | inspect 16 candidates, each at most 256 × 256 with exact byte count |
| DBusMenu | 128 nodes, depth 8, 256 KiB reply, unique node IDs |
| Media players / player reply | 8 / 512 KiB |
| Artwork | one worker/image; 2 MiB encoded; 4096 per dimension and 8 megapixels before decode; 256px output |
| Property refresh | event-driven, coalesced at 100 ms; selected menus only |
| Session-bus reconnect | independent GDBusConnection; 3-second retry |
| Control status | four entries per collection per page, text previews, 8 KiB frame |

Service objects live at stable addresses. Async work holds the application
until completion, cancellation drains on shutdown and transport epochs discard
callbacks from previous connections. No service names allow replacement or
request replacement. Session-bus restart uses a new connection instead of GIO's
shared connection, which GApplication may retain after it closes.

## CLI

```sh
pearlctl notifications toggle
pearlctl media toggle
pearlctl tray toggle
pearlctl session status                 # follow next_offset for additional pages
pearlctl session action --command dnd_on
pearlctl session action --command dnd_off
pearlctl session action --command clear_history
pearlctl session action --command dismiss --notification 42
pearlctl session action --command invoke --notification 42 --text default
pearlctl session action --command select --generation 7
pearlctl session action --command play_pause --generation 7
pearlctl session action --command seek --generation 7 --position 60000000
pearlctl session action --command tray_menu --generation 9 --menu-id 0
pearlctl session action --command tray_click --generation 9 --revision 3 --menu-id 5
```

Media commands also include `play`, `pause`, `stop`, `next` and `previous`; tray
commands include `tray_activate` and `tray_secondary`. Generations/revisions come
from status, never labels or list positions. Position is in microseconds. A queued
reply acknowledges dispatch; later status/signals report the actual outcome.
All mutations retain Pearl's Aqueous-ready, same-display, same-UID and unlocked
checks. Wrong/missing action fields are rejected before execution.

## Verification and sources

`zig build test-session-services -Doptimize=ReleaseSafe` runs real protocol clients
and controlled service implementations on private session buses and headless
Aqueous. GTK keyboard tests use the instrumented binary's read-only focus probe;
name conflicts and bus restart also run the production executable. All tests
use `G_DEBUG=fatal-warnings`. Fixtures never connect to the host session/system
bus. No T08 physical radio/scan authorization is implied by this task.

Protocol references: [Notifications 1.2](https://specifications.freedesktop.org/notification/latest/protocol.html),
[MPRIS Player](https://specifications.freedesktop.org/mpris/latest/Player_Interface.html),
[StatusNotifier](https://specifications.freedesktop.org/status-notifier-item/latest-single/),
[KDE watcher introspection](https://github.com/KDE/plasma-workspace/blob/master/xembed-sni-proxy/org.kde.StatusNotifierWatcher.xml),
and [DBusMenu introspection](https://github.com/gnustep/libs-dbuskit/blob/master/Bundles/DBusMenu/com.canonical.dbusmenu.xml).
