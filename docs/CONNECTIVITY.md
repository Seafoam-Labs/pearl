# Network and Bluetooth (T08)

Pearl's control center now has NetworkManager and BlueZ controls implemented in
Zig 0.16.0 using the pinned Ghostty GIO/GTK bindings. No libnm wrapper, subprocess
service adapter, custom C bridge, or additional generated dependency is needed.
The default bar includes `network`; optional `bluetooth` shows the connected-device
count. Each opens its corresponding compact Network or Bluetooth page directly.
Overview links and the fixed section chooser also reach both pages. Opening a
page does not start a scan or discovery.

Radio-off controls reflect backend availability: Wi-Fi connection/scan buttons
are disabled while its radio is off or hardware-blocked, and Bluetooth device
actions are disabled when their adapter is off. Saved Wi-Fi activation uses the
same device readiness check as nearby networks; the Wi-Fi gate does not disable
wired adapters. Compact captions wrap on narrow outputs with enlarged text.

## NetworkManager

The Network card exposes the Wi-Fi radio, adapter state/disconnection, explicit
scanning, nearby access points and saved profiles. It shows connectivity, captive
portal, limited-connectivity, unavailable, pending and error states. Expand
“Adapters, nearby and saved networks” to select a target. Adapters are identified
by D-Bus object path; labels and SSIDs never become command arguments.

Open, WPA/WPA2 personal and WPA3 SAE networks are supported. Selecting a new
access point uses `AddAndActivateConnection2` with `persist=volatile`, automatic
connection disabled and `psk-flags=NOT_SAVED`. NetworkManager completes device/AP
settings; Pearl returns the password through its SecretAgent. A temporary profile
is removed by NetworkManager after disconnection. Existing profiles use
`ActivateConnection`, preserving their existing settings and secret-storage policy.
Pearl never calls Settings.GetSecrets or writes credentials to its preferences.

Saved profiles come from Settings.Connection.GetSettings, with serial bounded
requests. `Updated` invalidates their cached details, including an in-flight
read. Device.AvailableConnections maps profiles to compatible present adapters.
Wired profiles are supported through these saved entries. New wired profiles,
VPN, WEP, enterprise/802.1X, hidden-network creation and advanced authentication
are handed to the installed `nm-connection-editor.desktop` using GIO activation.
If it is absent, the card explicitly identifies the application to install.
There is no fallback that treats an unsupported secured network as open.

The exported SecretAgent at `/org/freedesktop/NetworkManager/SecretAgent` registers
with AgentManager. Requests must come from the current unique NetworkManager
owner, permit interaction and match the user-initiated profile/SSID and security
mechanism. Only one conversation may be pending. Other requests receive NoSecrets;
SaveSecrets explicitly reports that Pearl does not store credentials. Cancel and
DeleteSecrets have defined replies. Rejected credentials open a fresh masked
entry instead of reusing the previous password.

GTK PasswordEntry uses its password buffer and has the peek icon disabled. The
entry clears on submit, cancel, prompt replacement, popup destruction, daemon
loss and session locking. Pearl's short-lived validation copy is explicitly wiped.
GTK and GDBus manage their own transient memory; this is not a guarantee that every
intermediate copy is locked or zeroed. Secret text is excluded from the service
model, CLI request schema, diagnostics, OSD and persistent shell configuration.

## BlueZ

The Bluetooth card lists adapters and devices, with power, discovery, pair,
connect/disconnect and explicit trust/remove-trust actions. Pairing does not
silently trust a device. Device aliases are accompanied by addresses in the panel
to distinguish equal names. Authoritative Paired, Connected, Trusted and Blocked
properties determine the controls.

Pearl registers a client-local `KeyboardDisplay` Agent1 at
`/org/aqueous/Pearl/BluetoothAgent`. It does not take over the system's default
agent. Only the current BlueZ unique owner may call it, and the device must match
an active user-initiated pair/connect request in the open panel. Agent1 supports
PIN/passkey input, zero-padded passkey confirmation, display PIN/passkey,
authorization, service authorization, Cancel and Release. PIN/passkey text is
shown or entered only in GTK; status and logs contain no codes.

Discovery begins only on explicit request, with one lease on one chosen adapter.
A 30-second timer, Stop discovery or closing the panel releases Pearl's lease.
Closing while StartDiscovery is pending still sends StopDiscovery after its reply.
Pearl does not stop leases held by other applications. A failed stop is reported;
BlueZ ultimately owns radio behavior. Pairing has a 90-second deadline and sends
CancelPairing on cancellation. Connect cancellation sends Disconnect and repeats
it if a delayed successful Connect reply arrives afterward. Cancellation cannot
undo a pairing that BlueZ already completed; trust remains a separate action.

## Ownership, limits and availability

`src/services/dbus_peer.zig` is a shared asynchronous ObjectManager transport.
NetworkManager uses `/org/freedesktop`; BlueZ uses `/`. Signals coalesce into one
snapshot request after 100 ms. A dirty bit retains changes arriving during the
request. Reads have a five-second deadline; unavailable buses retry after three
seconds. There is no daemon auto-start and no synchronous D-Bus call on GTK's
main loop. Each outstanding callback holds the application through shutdown.

Every method targets a captured unique owner. Owner changes discard snapshots,
agent exports, prompts and pending intent; stale completions cannot affect a new
daemon. A disconnected system bus recreates proxies and agents. Reply signatures
and property types are checked. The retained snapshot is capped at 512 objects
and 2 MiB; exceeding the cap fails closed with a visible error. GDBus may allocate
the incoming message before Pearl can enforce these application-level limits.

Network state retains at most eight managed Ethernet/Wi-Fi devices, 64 access
points and 32 saved profiles. A saved settings reply is capped at 64 KiB. BlueZ
retains eight adapters and 64 devices. Truncation is reported. Object paths over
512 bytes are excluded; SSIDs preserve their original bytes up to 32 bytes and
get safe labels when binary or control-containing. A Wi-Fi scan has a 15-second
request deadline/cooldown. NetworkManager provides no matching CancelScan method;
closing the panel never schedules another scan.

One connection/device mutation is pending per service. Radio/property calls have
short deadlines; Wi-Fi activation and pairing allow up to 90 seconds. Closing the
page, changing its output, or closing its flyout cancels only that page owner's
conversation and discovery. Another frontend's work remains active. Losing
Aqueous readiness or locking the session revokes all interactive leases.
Established connections survive ordinary navigation and close. Removed targets cannot be
reused for a pending prompt. Cancelling a Wi-Fi activation sends Disconnect and
deactivates any active-connection path returned by a late activation reply.

GTK updates occur in the surface manager's idle reconciliation. Rows retain
widgets while identities remain stable, preserving typed credentials across
unrelated property changes. Explicit focus metadata exists only in the private
instrumented build; it never logs entry contents or pairing codes.

## CLI and testing

```
pearlctl connectivity status [--offset N]
pearlctl connectivity action --service network|bluetooth --action ACTION \
    --generation N [--path OBJECT_PATH]
```

Status returns at most four entries per page, with `next_offset`. Entries include
network devices, access points, saved profiles, Bluetooth adapters and devices.
The network/Bluetooth generation must come from current status. Scan/connect/pair
operations require the corresponding open compact Network or Bluetooth page.
Use `pearlctl control-center show --page network` or `--page bluetooth`.
Commands use that view's [owner lease](SETTINGS_SERVICE_OWNERSHIP.md) and cannot
answer or cancel another frontend's prompt. Control commands remain scoped to the
current Aqueous session/display and are rejected while the session is locked.
Passwords and pairing confirmations are deliberately available only through GTK.

Network actions: `scan`, `connect`, `connect_saved`, `disconnect`, `enable`,
`disable`, `cancel`. Bluetooth actions: `discover`, `stop_discovery`, `pair`,
`connect`, `disconnect`, `trust`, `untrust`, `enable`, `disable`, `cancel`.
Device actions require `--path`; network radio/cancel and Bluetooth stop/cancel
omit it. Accepted mutations return `queued:true`; status reports actual outcomes.

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-connectivity -Doptimize=ReleaseSafe
python3 scripts/check-connectivity-hardware.py
```

The integration test creates private NetworkManager/BlueZ peers and an independent
private system bus under a private Aqueous compositor. Real GTK keyboard input
answers password and pairing prompts. It exercises rejection/retry, cancellation,
late replies, removed devices, hostile bus callers, owner replacement, bus restart
and limits. It audits status/log/config output for the synthetic credentials.
Neither the fake peers nor the normal integration tests access host services.

The hardware script explicitly connects the production Pearl binary to host
services while keeping its compositor/session bus private. Its default is
read-only. `--scan` is an opt-in physical test: temporarily enable Wi-Fi, scan,
run a short Bluetooth discovery and restore the original radio state. Enabling
Wi-Fi may autoconnect a pre-existing NetworkManager profile. It never explicitly
activates networks, pairs devices or disconnects the existing Bluetooth headset.
Physical scan acceptance is recorded separately from read-only enumeration.

## Primary API references

- [NetworkManager methods and temporary activation](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html).
- [NetworkManager SecretAgent](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.SecretAgent.html).
- [Wi-Fi security settings](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless-security.html).
- [BlueZ Agent1 and AgentManager1](https://bluez.readthedocs.io/en/latest/agent-api/).
- [BlueZ Adapter1](https://bluez.readthedocs.io/en/latest/adapter-api/) and [Device1](https://bluez.readthedocs.io/en/latest/device-api/).
