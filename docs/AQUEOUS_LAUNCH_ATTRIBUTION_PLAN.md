# Custom desktop launcher attribution — standalone Aqueous plan

Status: deferred, 2026-09-24. Native reinvestigation found Pearl-side matching and
desktop-ID validation gaps. The current issue #3 fix plan requires no Aqueous
changes. This document is retained only as a separate future proposal for
per-window launch-origin tracking; it is not an implementation dependency.
No Aqueous source changes are included with this document.

Consumer: Pearl. User-visible bug:
[Seafoam-Labs/pearl#3](https://github.com/Seafoam-Labs/pearl/issues/3).
This document contains the compositor scope and proposed integration contract so
it can be implemented without access to Pearl's planning files.

## Problem and responsibility boundary

A custom `CustomOverride.desktop` launches a window whose Wayland app ID remains
`org.pearl.Override`. Pearl currently identifies it as the packaged
`org.pearl.Override.desktop`, displays that icon, and saves the packaged pin and
arguments. An explicit Pearl launcher choice works, but automatic attribution is
missing. Same-filename desktop overrides already work through GIO.

Aqueous should expose a dependable, optional per-window launch origin. Pearl owns
desktop discovery, user choices, icon rendering, pin persistence and actual GIO
launching. Aqueous owns correlation with window lifetime and publication in shell
state. Origin metadata is application identity evidence, not permission to launch
a command, grant focus or access another client's resources.

Observed local source entry points:

- `compositor/aqueous/Window.zig`: `unreliablePid()` returns Wayland client PID or
  XWayland's PID hint; `info()` supplies window metadata.
- `compositor/aqueous/ShellManager.zig`: window snapshots omit launch origin and PID.
- `compositor/aqueous/Server.zig`: `handleRequestActivate()` receives activation
  tokens and surfaces; it currently rejects requests without a seat before calling
  `window.requestActivate()`.

Verify these locations against the target Aqueous revision before implementation.

## Proposed contract to freeze with Pearl

Names below are proposals, not existing protocol support. Settle them in A1 and
keep the consumer and compositor fixtures identical.

Advertise optional shell capability `launch_attribution_v1`, default false for
old peers. Add this optional field to window snapshots and deltas:

```json
{
  "launch_origin": {
    "desktop_id": "CustomOverride.desktop",
    "source": "shell_launch"
  }
}
```

Omitted/null means unknown. Initial source values are `shell_launch` and
`external_launch`; they indicate provenance, not a confidence score. Publish only
established origins. Desktop IDs are at most 1024 UTF-8 bytes, no NUL/control
characters, absolute paths or traversal, and must use the agreed Pearl desktop-ID
validation rules. The ID refers to an installed desktop entry, never an Exec line.
Define unknown-source handling for future consumers before freezing the schema.

Provide an authenticated shell registration operation, provisionally
`launch.register`, with a caller-generated request ID, exact desktop ID and one
supported evidence variant: startup/activation token or a verified process
identity. A bare PID is not a process identity. The reply acknowledges registration
only, never successful launch or successful window attribution. Registrations are
session-bound, idempotent for identical request IDs/content, and reject conflicting
reuse. Use existing shell authorization and bounded command transport. Final
payload shapes depend on the A1 proof; do not ship an unimplemented evidence variant.

Retain established origins with windows for the compositor lifetime, including
Pearl disconnect/restart. Pending registrations expire after 30 seconds and are
capped at 128 per authorized shell connection, with a bounded session-wide cap.
Specify deterministic eviction/rejection and bounded storage for activation events
that arrive before registration. Drop pending registrations on owner disconnect;
established window metadata remains. Never export reusable raw activation tokens
or process environments in shell snapshots or diagnostics.

## A1 — prove correlation mechanisms and freeze the contract

Build small native fixtures before committing the protocol design:

1. Launch a custom desktop entry through GIO with a launch context. Observe its
   launch signals and the compositor's token-to-surface path. Prove whether the
   startup identifier reported to Pearl corresponds to information Aqueous can
   validate. Do not assume every toolkit supplies a usable token.
2. Exercise direct launches where Wayland credentials identify the launched
   process. Verify UID, PID and process start time with race-resistant reads;
   explicitly reject PID reuse. Determine how the shell supplies verifiable process
   identity when the process exits before inspection.
3. Exercise an external GIO launch. Assess the narrow direct-process case using
   GIO's desktop-file/process markers, checking their availability in the deployed
   GLib source/runtime. An inherited desktop marker alone is insufficient: require
   association with the same verified window-owning process and the effective
   installed desktop entry. Read only bounded needed fields, never log environments.
4. Exercise wrappers, terminals, Flatpak, XWayland and D-Bus activation. Identify
   which mechanisms preserve evidence and which do not. Parent-process ancestry,
   executable similarity and last-launch timing must not establish origin.

Exit: a written support matrix, agreed exact operation/error/schema definitions,
and demonstrated automatic direct Pearl and external GIO cases. Unsupported cases
must remain unknown. If the external case cannot be proven, record the additional
launcher integration needed; Pearl-only support does not complete the original bug.

## A2 — implement bounded origin tracking

Add a focused component, provisionally `LaunchAttribution.zig`, for pending
registrations, evidence verification and established origins. Keep filesystem or
process inspection off the compositor's latency-sensitive event handling path;
revalidate window/process lifetime when asynchronous work completes.

Validate registration ownership and token eligibility before using a token as
evidence. A launch token targeting an already established window must not relabel
that window merely because an existing process handled a second launch request.
Conflicting or ambiguous evidence leaves origin unknown or preserves the already
established origin; it must never use last-writer-wins behavior. Establish exact
multi-window process inheritance rules only where process identity proves them.

Keep focus policy unchanged. An origin association does not authorize activation;
an activation denial must not be bypassed to make attribution succeed. Design
origin handling around window creation/mapping and the real activation lifecycle,
including activation before mapping, consumed tokens and expired registrations.

For external desktop-file markers, map only an effective installed entry under
the session's XDG application roots. Reject stale/shadowed files, ambiguous ID
mapping and arbitrary paths. Define symlink handling explicitly and test it.
Do not execute or parse an arbitrary recovered command. Prefer a small existing
desktop-ID lookup facility; document any new runtime dependency before adopting it.

Exit: bounded work and memory, no false association under races, no focus-policy
change, and cleanup on process/window/connection/session teardown.

## A3 — publish durable window metadata

Attach an owned origin to `Window`; serialize it through `ShellManager` using
normal atomic snapshot/delta sequencing. A late establishment emits a window
update. Clear it when the window is destroyed, never reuse it for another opaque
window ID, and retain it across shell reconnects in the same compositor session.

Expose the capability only when its implementation is active. Validate old-client
handling of added fields/capabilities and test old/new peers in both directions.
Keep privileged registration unavailable to ordinary shell observers. Document
limits, null/unknown behavior, unavailable process information and registration
reply semantics in Aqueous's public protocol documentation.

Exit: a newly connected Pearl can recover every surviving established origin from
the snapshot without replaying launches or persisting raw tokens.

## A4 — acceptance and handoff

Required native and protocol tests:

- Custom vs packaged desktop IDs for both Pearl-style and external GIO launches.
- Snapshot, late delta, shell restart, disconnect and compositor-session reset.
- Two simultaneous custom profiles sharing an app ID; opposite launch/map order.
- Failed launches, PID reuse, exited processes, stale tokens, forged or inherited
  markers, conflicting registrations, oversized fields, expiry and capacity limits.
- Multiple windows, existing-process activation and startup before registration.
- Direct Wayland and native XWayland; do not treat XWayland client PID hints as
  authenticated credentials.
- Wrapper, terminal, Flatpak and D-Bus cases with explicit expected attribution
  or unknown result; missing PID/token must remain supported as an unknown result.
- Unauthorized registration and unchanged focus-stealing prevention.
- Old/new consumer compatibility and compositor event-loop responsiveness under
  slow/failed process inspection.

Deliver the compositor revision, protocol documentation, fixtures, test results,
runtime dependencies and support matrix. Pearl acceptance must then prove custom
icon → pin → close → relaunch with the exact custom arguments, without a manual
launcher choice. Do not describe all external launches as supported unless the
evidence establishes that claim.

## Reference constraints

GIO launch signals may fire once per spawned instance; PID can be zero or absent,
especially for D-Bus activation. Account for those cases explicitly.
([GIO launched](https://docs.gtk.org/gio/signal.AppLaunchContext.launched.html),
[GIO launch-started](https://docs.gtk.org/gio/signal.AppLaunchContext.launch-started.html))

The XDG activation protocol transfers tokens to surfaces and allows optional app
identity hints; a token is not inherently an authoritative desktop-file identity.
Inspect the target revision's primary protocol XML and wlroots implementation:
`/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml`.

Desktop IDs derive from installation-relative filenames and are subject to XDG
precedence. Preserve these semantics when validating external evidence.
([Desktop Entry Specification](https://specifications.freedesktop.org/desktop-entry/latest/file-naming.html))
