# Settings service-view ownership

The compact flyout and a future Settings frontend share the shell's service
objects. F3 introduces the in-process ownership interface below. The standalone
plan still owns its authenticated, versioned frontend transport.

## Page lifetime

Network, Bluetooth and Power expose `acquireView() !Owner`,
`releaseView(owner)` and backend-only `revokeViews()`. A frontend acquires a
lease on page entry and releases exactly that lease on departure or disconnect.
The flyout disconnects widget callbacks and clears credential entries before
releasing its lease. Audio remains observed by the shell for bar state and has
no page-owned polling or prompt.

Each service supports at most 16 concurrent leases. Exhaustion returns `Busy`.
Tokens increase monotonically and are never reused during the service lifetime,
including across lock/revocation. A duplicate release is harmless. Revoked
tokens cannot start or answer work after unlock; a new page entry must acquire
a new token. Lock, lost compositor availability and display/session mismatch
disable acquisition and revoke all interactive leases.

Power starts page polling with the first lease and stops it after the last lease.
Network and Bluetooth acquisition does not start scanning or discovery.

## Operations and prompts

- Network scan, access-point connection and saved-profile activation require
  the initiating owner plus the current service generation and object path.
- Bluetooth discovery and device/adapter requests require the same identifiers.
- `ownsPrompt(owner)` filters prompt presentation; an answer also requires the
  current prompt serial. Foreign, expired and revoked answers return
  `Unavailable`. Credential values never enter status or focus-restoration data.
- `cancelOwned(owner)` cancels only that owner's pending operation.
  `stopDiscoveryOwned(owner)` stops only that owner's discovery lease.
- Releasing a Network lease invalidates that owner's pending scan callback and
  cancels its unfinished activation/prompt. Releasing a Bluetooth lease cancels
  its unfinished operation/prompt and stops its discovery, including a delayed
  successful discovery start. Established connections are retained.
- Existing per-service operation serialization, scan cooldowns, prompt deadlines,
  identity/generation checks and error mapping remain authoritative. A second
  owner does not create an independent simultaneous pairing or activation slot.
- Service loss cancels the affected operations and invalidates generations while
  retaining live view interest, so a visible page can recover when service returns.

## Standalone transport integration

The [Settings frontend API](SETTINGS_FRONTEND_API.md) defines the process boundary.
S4 binds backend-issued leases to its authenticated
frontend connection and service. It never accepts an arbitrary numeric token as
authorization: these tokens identify ownership, not callers. Disconnect releases
only that connection's leases. Route prompt updates only to their owning frontend,
and require both connection ownership and prompt serial on answers.

The existing `pearlctl connectivity action` interactive commands use the active
matching flyout page's lease; they cannot answer or cancel another frontend's
prompt. Existing immediate service operations retain their validation.

`test-settings-lifecycle` exercises a second owner's interest and operations
through an integration-build-only fixture. It covers cross-owner denial,
independent cleanup, lock revocation and stale-token rejection. S4 `test-settings-services` additionally exercises independent real frontend
connections, prompt privacy, owned discovery and display-preview rollback.

The normal app uses one connection for Pearl/live pages and another for Aqueous.
Page changes release the first connection’s leases while retaining the second
connection’s window-wide preview. Close waits for native rollback acknowledgment.
Lock or connection loss revokes only the relevant owned work; unlock never
re-presents the window automatically. Same-page activation preserves interest.

## Notification filter ownership

The shell surface manager supplies committed notification rules to its existing
Session/Notifications service at startup and preference publication. That service
owns the compiled Unicode matcher and decides delivery before history insertion.
The standalone Notifications page edits only the shared Pearl draft. Its sample
tester is a bounded, read-only backend request scoped to a current view and draft
revision; it never registers a notification service or sends a Notify call.
Live history refreshes update separate hosts above/below the filter editor so
sample fields and an open rule dialog retain their input and focus.

## Rule builder ownership

`rule_builder.zig` owns no service, matcher or persisted schema. Notification
filters retain Pearl preference ownership; window rules retain Aqueous ownership.
`window_rules_view.For` lives as long as the Aqueous view. Its modal arena owns
captured schema/values and survives page rebuilds. Page callbacks are disconnected
and page controls detached before their arena resets; modal callbacks and widgets
are destroyed before modal storage is released. Lock, suspension, disconnect and
navigation hide the dialog without discarding input. Save compares snapshot
version, shared revision and draft digest; conflicting input remains visible.
Collection moves are isolated at retention and canonical-request validation,
including edits arriving through other frontends or Advanced.
