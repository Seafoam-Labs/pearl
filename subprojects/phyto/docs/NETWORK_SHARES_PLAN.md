# Saved network connections for Phyto

Status: native workflow implemented · October 12, 2026.

See the [implementation and qualification report](NETWORK_SHARES_IMPLEMENTATION.md)
for delivered behavior, native captures, test results and remaining release checks.
The design contract and milestones below are retained for reference.

Phyto will mount and browse SMB, SFTP and WebDAV shares, remember their connection
details, and let users choose when each saved connection reconnects: **When Phyto
opens** or **When I click the network device**. Disconnected devices remain in
Places. The default is connection on click; startup connection is an explicit
per-device choice.

This covers [issue 13](https://github.com/Seafoam-Labs/pearl/issues/13), including
the initial protocol list in its comments, and the additional persistence and
reconnection requirements. [Open the interactive process mockup](mockups/network-shares/index.html).
The browser prototype remains a design reference; the native implementation is
described in the report above.

## User process

1. Open **Network** in Places and choose **Add connection…**. Also expose this
   action in More options. Discovered locations can offer **Save connection…**;
   discovery is supplementary, and entering an address must work independently.
2. Enter a display name and server address. Accept `smb://nas.example/Design`,
   `sftp://dev.example/home/zoey`, `davs://cloud.example/remote.php/dav/files/zoey/`
   and `dav://` for unencrypted WebDAV. Explain the protocol with examples. Keep
   paths case sensitive and correctly escape spaces; support IPv6 and custom
   ports. Reject passwords in addresses, unsupported schemes, query/fragment
   components, invalid hosts and malformed ports before saving.
3. Choose **Reconnect** using two radio options:
   - **When Phyto opens** — connect in the background when the app starts.
   - **When I click the network device** — connect only when opening that device.
4. Choose **Save and connect** or **Save for later**. Both persist the profile
   before any connection attempt; a failed mount must not discard the saved
   device. Save for later performs no mount, even with startup selected: that
   preference applies on the next app launch. Cancel does not create a profile.
5. For an explicit connection, present provider authentication when required.
   Password saving is a separate choice from saving the connection profile.
   Success opens the requested folder in the originating tab; failure retains
   the device and offers a relevant recovery action.
6. On a later launch, restore every saved device immediately. Start background
   attempts only for startup profiles. Clicking a disconnected device with
   either policy connects and then opens it. Clicking a mounted device opens it
   without another mount request.
7. **Connection settings…** edits name, address and reconnect policy. **Disconnect**
   unmounts when supported but preserves the profile. **Forget connection…**
   removes only the saved profile and explains that remote files and an existing
   mount remain. Unmounting is a separate action because other apps can use it.

In Places, place saved devices in a **Network devices** group. Show names,
protocol icons and text status; put longer endpoint and reconnect details in
Network's saved-device list and settings. Merge matching active mounts into the
saved row, rather than showing a duplicate device. Unsaved mounts keep the
existing device behavior. Existing bookmarks remain bookmarks and never gain
startup connection behavior implicitly.

## Reconnection and failure behavior

| Event or state | Behavior |
| --- | --- |
| First interactive app window in a new process | Queue startup profiles after the window is usable; retain its requested local location. |
| Additional window or tab in that process | Reuse the coordinator; do not rerun startup connection. |
| Click a saved device or activate it with Enter | Reuse a mounted target, join its in-flight attempt, or start one interactive attempt. |
| Startup success | Mark Connected; never change the active folder or steal focus. |
| Startup needs credentials, keyring unlock or a trust decision | Show Sign-in required or Review required on the device; no unsolicited modal. Clicking it resumes interactively. |
| Offline, timeout or unreachable server | Keep profile and display Could not connect with Retry and Settings. No retry loop. |
| Backend missing | Explain which protocol support is unavailable; retain profile. Do not install packages automatically. |
| Cancel connection | Cancel the operation and leave the device disconnected and saved. |
| Explicit disconnect | Unmount asynchronously, retain profile and suppress further automatic attempts for this process. Busy mounts offer cancellation, not force-unmount by default. |
| Network disappears after connection | Update mount state, retain navigation/history and show recovery; do not delete the device. |
| Preference changes from on-click to startup | Save now; it takes effect at the next process launch. Connect is a separate explicit action. |
| Save fails | Report that changes were not saved, keep the editor values, offer Retry save. Do not claim persistence or start the requested mount. |

Proposed limits: at most two background attempts concurrently; one in-flight
attempt per mount identity per process; a 20-second network-attempt deadline.
Interactive time spent answering a prompt is excluded from that deadline.
Cancel/retry use new request generations so late callbacks cannot change the
newer state. Network restoration does not automatically retry failed devices in
this first release; users can click Retry without restarting Phyto.

Phyto currently uses `G_APPLICATION_NON_UNIQUE`. Separate processes therefore each
get a startup pass. Check existing GIO mounts before requesting a new mount and
treat an already-mounted result as success. Do not promise a cross-process
single-flight guarantee; GVfs/backend behavior and two-process launch races need
integration coverage. No background daemon or system-login automount is added.

## Persistence and credentials

Store versioned profiles in `$XDG_CONFIG_HOME/phyto/connections.ini`, separate
from the existing `preferences.ini`. This isolates profile edits from unrelated
preference saves. Use a dedicated process-shared store with stable UUIDs, atomic
private writes, and a private parent directory, following the existing GIO write
pattern. Read profiles before building Places, without making network calls.

```ini
[Connections]
version=1

[Connection 80d434a0-1df1-4c15-bc77-2d44fc51e5a6]
name=Studio NAS
uri=smb://nas.example/Design
reconnect=on-open

[Connection 33fa80bf-2e75-49ce-9945-c2e5d36434a4]
name=Development server
uri=sftp://dev.example/home/zoey
reconnect=on-click
```

Store only stable profile data: identifier, name, normalized URI and policy.
Username/domain hints may be separate optional fields when required by a backend;
they are not passwords. Never persist connected/error/connecting state, passwords,
tokens, private keys or unredacted authentication messages in this file. Do not
put secrets into URIs, logs or diagnostic probes. Delegate credentials, optional
remembering and SSH key/agent handling to the installed GIO/GVfs authentication
mechanisms and desktop keyring. If credentials cannot be retrieved unattended,
startup pauses at Sign-in required.

Default unknown reconnect values to `on-click`. A missing file is an empty list;
skip individual invalid profiles with a visible recovery notice. Preserve unknown
fields in supported versions. Unsupported newer versions must not be overwritten.
Detect concurrent external edits using GIO etags; reload and merge by profile ID
or report a conflict instead of silently replacing another process's changes.
Monitor changes to refresh open windows and invalidate stale attempts.

Normalize scheme/host/default ports conservatively, preserve path and account
identity, and detect exact duplicate targets before save. Offer to edit an
existing profile instead of silently adding another. Do not merge different
accounts on the same host. Multiple folders on the same share may have distinct
profiles but should share the backend mount. Editing an endpoint cancels its
pending request; it does not unmount the old endpoint used by other tabs/apps.

## Native implementation

| Existing code | Planned change |
| --- | --- |
| `src/platform/preferences.zig` loads shared GLib key files and uses GIO `replaceContents` | Use its conventions in a new `platform/connections.zig` store; add etag conflict handling and change notifications. |
| `src/window.zig` builds Network, bookmarks and live mounts in `refreshPlaces` | Add saved rows, reconciliation with live mounts, add/edit dialogs and persistent settings access in narrow Places. |
| `src/main.zig` owns application activation and multiple windows | Own a process-wide connection coordinator; queue startup once after the first window is ready; cancel work during shutdown. |
| `src/platform/applications.zig` handles existing `GVolume` mount/unmount operations | Introduce `platform/network_mounts.zig` for URI targets that have no `GVolume`; share error and unmount conventions. |
| `src/tab.zig` owns navigation and metadata request generations | Route explicit saved-device navigation through the coordinator, then enumerate the URI after mounting. Retain originating tab ID and generation. |
| `src/context.zig`, `src/core/context.zig`, `src/context_menu.zig` and actions | Add stable saved-connection targets and Connect, Cancel, Disconnect, Settings and Forget actions with state-aware availability. |

Use asynchronous [`GFile.mount_enclosing_volume`](https://docs.gtk.org/gio/method.File.mount_enclosing_volume.html)
with a cancellable and its finish callback for URI mounts. Check for an existing
enclosing mount first, reconcile `GVolumeMonitor` events and handle already-mounted
results. Keep runtime state separate from stored profiles:
`disconnected → connecting → connected | needs-interaction | failed`.
Provider authentication uses [`GMountOperation`](https://docs.gtk.org/gio/class.MountOperation.html);
explicit user requests can use [`GtkMountOperation`](https://docs.gtk.org/gtk4/class.MountOperation.html)
parented to the originating window. For background attempts, supply a noninteractive
policy that defers password/trust prompts. Verify stored-credential lookup and
error classification against the shipped backends; simply hiding a dialog is
not a sufficient implementation.

Build an immutable navigation intent containing window/tab ID, tab generation,
profile ID/revision and target URI. Mount completion updates shared status but
only navigates when that intent is still valid. Startup has no navigation intent.
Closing a window, switching the target folder, forgetting a profile or cancelling
must release subscribers and prevent stale navigation. Shutdown must release
cancellables, signal handlers, mount-operation objects and application holds.

Continue using GIO URIs in listing and operations; remote files may have no local
path. Audit open/copy/rename/delete and clipboard capability checks for all three
protocols; keep local-only preview, terminal and provider actions unavailable
where required. Never use shell mount commands or construct shell strings from
addresses. Unknown SSH hosts and TLS errors require explicit provider trust
handling; never auto-accept them during startup.

## Delivery milestones

1. **Profiles and settings.** Implement URI validation, versioned store, conflict
   handling, immutable profile IDs, add/edit/forget UI and disconnected Places
   rows. Exit: profile and per-device choice survive process restart and save
   failure is recoverable without claiming success.
2. **Explicit mounting and browsing.** Implement URI coordinator, authentication,
   cancellation and mount reconciliation. Connect on device click and open the
   intended folder. Exit: authenticated SMB, SFTP and secure WebDAV can mount,
   list, navigate and disconnect with an installed backend.
3. **Startup policy and recovery.** Add bounded startup queue, no-focus-stealing
   behavior, deferred interaction and duplicate-attempt guards. Exit: mixed
   policies work on relaunch, in multiple windows and under offline/cancel races.
4. **Beta qualification and documentation.** Extend the existing private native
   harness, package/backend dependency guidance and user docs. Capture native
   dark/light/narrow screens and sign off the protocol matrix below. The browser
   mockup verifies the design only.

Direct addresses are required for beta. Automatic server discovery improvements,
system-wide mounts, NFS/FTP, background retry daemons, credentials management UI
and offline file synchronization are separate work.

## Acceptance and verification

- Restart with mixed startup/click profiles: all rows return; only startup targets
  receive requests. Additional tabs/windows do not trigger another startup pass.
- Click an on-demand device: one mount attempt, authentication if needed, then
  enumeration in the originating tab. Double clicks and already-mounted targets
  do not produce duplicate prompts or rows.
- Verify save-for-later and failed-first-connect persistence; edit/restart,
  forget/restart, duplicate targets, unknown policy/version, malformed records,
  unwritable config and concurrent-process edits. Inspect files for secrets.
- Test offline start, DNS failure, timeout, denied access, missing backend,
  locked/missing keyring, incorrect credentials, unknown SSH host, TLS failure,
  busy disconnect, cancel, late callback, profile edit/removal during connection,
  window close and process exit. No focus stealing or stale navigation.
- Use isolated SMB, SFTP and WebDAV fixtures with disposable accounts to validate
  listing, nested-folder navigation and allowed read/write operations. Include
  guest SMB, SMB domain auth, SFTP password/key authentication, DAV/DAVS, custom
  ports, IPv6, escaped spaces and non-ASCII paths where supported by the backend.
- Preserve local browsing, bookmarks, removable-device mounting, independent tabs,
  split panes and remote preview restrictions. Exercise existing native and
  context-menu regression suites after integration.
- Check keyboard-only radio selection, Enter activation, Escape cancellation,
  focus return, visible status text, accessible names, Orca, 200% text, narrow
  Places, dark/light and native GTK themes. Connection failure must never block
  navigation to local files.

The [mockup guide](mockups/network-shares/README.md) documents the illustrative
scenarios, stored demo metadata and browser verification separately from these
native acceptance requirements.
