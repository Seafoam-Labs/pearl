# Aqueous input activity dependency

Global input activity is **not implemented** in Pearl's plugin system. Inspection
of the pinned Aqueous IPC/native protocol sources found no supported aggregate
activity feed. Pearl does not use `/dev/input`, input-group membership, root
helpers, text-input interception or the RemoteDesktop portal as a substitute.
The current guest API reports availability accurately and supports local clicks
and an explicit synthetic Preview event.

Before enabling the real activity feature, Aqueous needs a reviewed, versioned
extension with all of these properties:

1. Bind it to the authenticated Pearl shell/session identity. It must not allow
   arbitrary Wayland clients to subscribe to global input. Capability negotiation
   must distinguish unsupported, denied, suspended and available.
2. Aggregate within the compositor, with bounded counts and at most one batch
   per 100 ms. Include press categories/counts only. Never transmit keycodes,
   keysyms, Unicode, modifier state, text, window identities, pointer coordinates,
   raw timestamps or device identifiers. Exclude key-repeat by default.
3. Suppress activity at lock preparation, while locked/inactive, and during
   authentication. Clear pending counts when the source is suspended, disconnected
   or revoked. New subscriptions start from zero with a new generation.
4. Pearl must share one subscription among explicitly granted plugins, recheck
   session/generation/grants before dispatch, and coalesce events while a helper
   is busy. The existing `activity` event's count must be clamped and no backlog
   may cross revocation or unlock.
5. Acceptance must type in another application in a private compositor session,
   verify the cat's poses, record event-to-pose latency and inspect payloads for
   privacy. Tests must cover lock preparation, polkit, inactive sessions,
   disconnects, repeat/burst input, multiple plugins and permission revocation.

This is a dependency specification, not a claim that an Aqueous extension with
these semantics exists. The final adapter must cite and pin the actual upstream
protocol revision. Preview events cannot satisfy the real-input acceptance gate.
