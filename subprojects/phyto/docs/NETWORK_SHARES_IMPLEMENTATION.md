# Saved network connections implementation

Phyto now saves SMB, SFTP and WebDAV connections and reconnects each device either
when the process opens its first window or when the user opens the device. This
implements the native workflow in the [network shares plan](NETWORK_SHARES_PLAN.md)
for [issue 13](https://github.com/Seafoam-Labs/pearl/issues/13).

## Delivered behavior

- Network provides saved devices, add/edit dialogs, connection status and recovery
  actions. Devices remain in desktop and narrow Places while disconnected.
  Keyboard-accessible device context menus provide Connect/Open, Cancel,
  Disconnect, Settings and Forget. Remote location/mount menus can save a profile.
- Names and normalized URIs are persisted with UUID identities and individual
  reconnect policies. Save for later never mounts. Save and connect persists first.
  Failed saves retain form values and do not start a mount. Editing the address
  cancels stale requests; forgetting leaves existing mounts and remote files intact.
- The coordinator shares attempts across windows, queues at most two background
  attempts, reuses active GIO mounts and checks originating tab generations before
  navigation. Startup never navigates or opens authentication/trust dialogs.
- Explicit connections use native GTK mount authentication, including provider
  password remembering. Silent startup defers password and trust questions;
  clicking a device resumes interactively. Connection attempts have a 20-second
  network deadline, excluding time in an interactive GTK prompt. Cancel and close
  cancel outstanding work; there is no network-restoration retry loop.
- Mounts represented by a saved device are not duplicated in Places. Shared-mount
  identity includes account and authority; SMB includes the share. WebDAV roots
  are treated conservatively and GIO remains authoritative about mount reuse.
- The versioned profile file uses private atomic replacement, etag conflict checks
  and an advisory lock for cooperating writers, including initial creation. A
  file monitor updates windows. Invalid records produce a notice, unknown policies
  default to on-click, and unsupported versions are not overwritten. Unrelated
  supported-version fields are preserved.

The implementation is split into `platform/connections.zig` (validation and store),
`platform/network_mounts.zig` (mount lifecycle), and `network_ui.zig` (native
controls). Main, window, tab and context-menu integration reuse the existing GIO
browsing and operation models. The Network overview uses an internal virtual
location; discovered servers remain available through GIO's network location.

Real DAV listings exposed optional `standard::is-hidden` and
`standard::is-symlink` attributes that the existing browser assumed were present.
Filtering, context capability checks and preview gating now read these booleans
without triggering GLib critical warnings when a remote backend omits them.
Remote preview restrictions remain in effect.

## Verification

The [native results](../artifacts/network/results.json) cover the complete saved
connection UI, process restart, policy edits, multiple windows, external-edit
conflicts, unavailable endpoints, native authentication and cancellation, profile
removal, private file permissions, remote-to-local copy and narrow layouts.
The fixture uses a private compositor and D-Bus session, disposable directories,
loopback servers and fictional credentials; GTK/GLib warnings are fatal.
All 12 native workflow checks and 24 unit tests pass. The startup certificate
fixture also guards against GVfs versions interpreting an aborted question as
the default answer: silent trust questions receive an unhandled response.

| Protocol | Evidence |
| --- | --- |
| SMB | Real guest Samba mount, native enumeration and byte-preserving GIO read, on a custom loopback port. |
| SFTP | Real OpenSSH public-key mount, native enumeration and byte-preserving GIO read, with a pinned temporary host key and custom port. |
| WebDAV | Real anonymous and password-authenticated mounts, native listing, startup/click policies, disconnect and remote-to-local copy. |
| Secure WebDAV | Untrusted loopback certificate is rejected or deferred during startup without a trust dialog. |

[SMB and SFTP results](../artifacts/network/protocols/results.json) use a rootless
Samba container and a temporary unprivileged SSH daemon. Client SSH configuration
and keys are confined to the test fixture; host accounts, SSH configuration and
system services are unchanged.

The unit suite adds six test groups for URI validation/normalization (including
IPv6, default ports, escaped spaces and credential rejection), mount identities,
profile lifecycle, competing writers, invalid/future schema, preservation of
unknown fields and failed-write recovery. Existing native browsing (13 groups)
and context-menu/file-operation (16 groups) regression suites pass; their evidence
is under `artifacts/network/regression-browse` and `artifacts/network/regression-menus`.

Reproduce the normal checks from `subprojects/phyto`:

```sh
zig build test -Doptimize=ReleaseSafe
zig build test-network -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
```

The optional SMB/SFTP qualifier accepts an instrumented Phyto binary and an
existing Linux root containing Samba, plus rootlesskit with configured subordinate
UID/GID ranges. It does not download an image or install packages:

```sh
python3 tests/network_protocols.py --binary /path/to/phyto-test \
  --server-root /path/to/linux-root --rootlesskit /path/to/rootlesskit
```

## Native captures

- [Network and saved devices](../artifacts/network/network-dark.png)
- [Connection editor](../artifacts/network/add-connection.png)
- [WebDAV browsing](../artifacts/network/webdav-browse.png)
- [Authentication](../artifacts/network/authentication.png)
- [Device menu](../artifacts/network/device-menu.png)
- [Light appearance](../artifacts/network/network-light.png)
- [Narrow Network page](../artifacts/network/network-narrow.png) and [editor](../artifacts/network/add-connection-narrow.png)
- [SMB](../artifacts/network/protocols/smb.png) and [SFTP](../artifacts/network/protocols/sftp.png)

## Release qualification boundaries

The application delegates protocol authentication, TLS validation, SSH trust,
key/agent use and credential storage to installed GTK/GIO/GVfs providers. The
fixtures do not qualify every server implementation or desktop keyring. SMB
domain authentication, SFTP password and key-agent permutations, trusted DAVS
against production certificates, locked keyring recovery, server disconnect during
active writes, Orca, 200% text and mixed-DPI remain manual release checks.

Separate Phyto processes each receive a startup pass. GIO reuses session mounts,
but cross-process single-flight mounting is not promised. Save conflicts are
reported instead of silently merging an open editor's changes. There is no
system-login automount, credential-management UI, offline synchronization or
background retry daemon. Backend packages are optional and missing support is
reported without deleting the saved profile.
