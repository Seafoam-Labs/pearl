# S1 — Application/backend boundary

Status: implemented, validated and approved by the user's instruction to implement S2.
Date: September 15, 2026.

## Review scope

- [Frontend contract and full inventory](../../../docs/SETTINGS_FRONTEND_API.md):
  all eleven routes, exact operation envelopes, existing service methods,
  preference/Aqueous draft revisions, transfers, completion reconciliation,
  prompt ownership, display-preview lifetime and explicit resource budgets.
- [`src/settings/protocol.zig`](../../../src/settings/protocol.zig): strict v1
  hello/heartbeat decoding, capability gating, identity and request-sequence
  checks, endpoint naming and model-derived limits.
- [`src/settings/server.zig`](../../../src/settings/server.zig): persistent
  nonblocking backend endpoint on verified session startup; existing transport's
  same-UID credentials, owned runtime directory, separate lock, bounded clients,
  partial-handshake expiry, disconnect and stale-socket cleanup.
- Shared route registry gains the existing Aqueous section IDs and validated
  application `Target`; the current Aqueous editor reads the same section list.
  Compact-page registry/selection behavior stays compatible with F1–F5.

The runtime currently advertises **handshake only**. The document describes
editor operations for S3/S4; it does not claim those adapters already exist.
There is no `pearl-settings` executable or application window at S1.

## Validation

All runs use Zig 0.16.0 and `-Doptimize=ReleaseSafe`. Writable build cache:
`ZIG_GLOBAL_CACHE_DIR=/home/zoey/Pearl/.cache/zig`.

| Check | Result / evidence |
| --- | --- |
| `zig build test` | **94/94 passed**, including four new protocol/target tests |
| `zig build test-settings-boundary` | **Passed**; [nine check groups](boundary/result.json), [final build log](boundary-build.log) |
| `zig build test-surfaces` | **Passed**; [results](regressions/surfaces/results.json) |
| `zig build test-settings-lifecycle` | **Passed**; [ten flyout/ownership check groups](regressions/lifecycle/results.json) |
| `zig build test-aqueous-settings` | **Passed**; current 0.8.2 target runs [22 structured editor/preview/receipt check groups](regressions/aqueous/metadata.json) |
| `git diff --check` | **Passed** |

The boundary fixture uses the production Pearl backend plus an independent
Python socket peer on two concurrently running private Aqueous sessions. It
checks successful hello/ping, explicit false editor capabilities, session/display
and version denial, missing hello, invalid/unsupported requests, repeated IDs,
fragmented frames, empty/invalid UTF-8/oversized frames, partial-input timeout,
eight-client exhaustion and reuse, no popup creation, crash EOF, stale-socket
recovery, fresh backend epoch and graceful cleanup. The existing surface suite
also retains its native-display verification and nested-session isolation checks.

An initial local build encountered the read-only default global cache; subsequent
builds used the workspace cache. The first private-session run hit the sandbox's
Unix-socket restriction; the rerun with approved execution permissions passed.
All service/compositor tests used private fixtures, not the user's live session.
The deliberately killed backend is expected to lack a graceful shutdown log.

Regression logs/results are copied into this evidence directory. The approved
flyout and prior milestone artifacts are preserved. No app screenshots belong to
this backend-only step.

## Required follow-through

The contract identifies changes that must precede advertising editing:

1. Make Pearl draft retention fallible and atomic; add a distinct draft revision
   checked by frontend, flyout and CLI. Acknowledged retention cannot silently
   ignore allocation failure or clear a newer draft after Apply.
2. Keep Aqueous preview ownership at connection/window scope. Its current
   popup destructor reverts previews and cannot be reused on app page departure.
3. Bind F3 service leases to connections; resolve no frontend operation through
   the active popup's owner token. Keep service agents in Pearl.
4. Implement document transfer, snapshot pagination, completion ledger,
   lock/reconnect state and owner-specific prompt replies before enabling those
   capabilities. The S1 tests do not claim to exercise those future adapters.
5. Verify frontend native identity/activation and per-session instance routing
   against the pinned bindings in S2. Physical desktop activation, accessibility
   and visual comparison remain later acceptance gates.

## Approval checkpoint

Approved to proceed to **S2 — executable and reference window**. See the
[S2 review checkpoint](../s2/REVIEW.md). S3 then delivers real Appearance/Advanced
draft editing after separate approval.
