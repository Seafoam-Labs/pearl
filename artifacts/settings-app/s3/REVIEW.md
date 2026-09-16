# S3 — Real Appearance and Advanced editors

Status: implemented, validated and approved by the user; S4 authorized.
Date: September 15, 2026.

## Delivered

The application and backend are **Zig**, using the pinned GTK4/GIO bindings.
Python supplies private integration fixtures only.

- Appearance edits the complete existing theme mode/variant/source/GTK name/seed,
  wallpaper mode/path/color, font family/size, density and reduced-motion fields.
  Form edits preserve every unrelated preference field. Advanced edits the full
  Pearl JSON, including pins, output overrides and export templates.
- Both hosts use one session-owned draft with independent monotonic revisions.
  Compare-and-swap rejects stale writes, Discard, Merge and Apply. Allocation
  failure leaves the previous draft intact. An in-flight Apply cannot clear a
  newer draft, even if its text is identical to the applied version.
- A fixed footer and cross-page badge distinguish draft retention from saving.
  Navigation and close flush local changes; acknowledged drafts survive normal
  close/reopen while the backend remains alive. Apply and Discard remain explicit.
- Advanced retains invalid/empty JSON. Independent external edits merge; overlapping
  conflicts remain available for review, including a normal read-only saved-JSON
  window. Save errors retain working settings and the draft; export errors report
  separately after a successful save.
- Wallpaper selection uses a normal transient GTK chooser and a cancellable
  asynchronous preview. Selection and preview do not write preferences.
- Backend restart retains a process-local candidate and requires explicit review.
  Recovery keeps Advanced reachable without replaying that candidate. A failed
  close offers **Keep open** or **Discard untransferred changes and close**.
  Lock hides the app and suspends editing; unlock alone never presents it.
- Settings-v1 enables Pearl editing and page snapshots, with 64-KiB documents,
  32-KiB UTF-8 chunks, connection-owned transfers, absolute expiry, fixed decoder
  budgets, bounded/coalesced events and operation receipts. Committed theme
  updates use events; the heartbeat is 15 seconds.
- The real editor starts at 480 pixels with normal or 24-pixel text. Compact
  navigation, scrolling controls and the fixed footer remain reachable. Footer
  action labels scale with the application font.

## Validation

All commands use `ZIG_GLOBAL_CACHE_DIR=/home/zoey/Pearl/.cache/zig` and
`-Doptimize=ReleaseSafe`. GUI, socket and lock checks run in private Aqueous,
Wayland, D-Bus, runtime and configuration fixtures with `G_DEBUG=fatal-warnings`.

| Target | Result | Evidence |
| --- | --- | --- |
| `build-settings build-settings-test test` | Production/test executables; 103 pure tests | [Build log](build.log) |
| `test-settings-appearance` | 15 S3 groups | [Results](final-acceptance/results.json), [log](appearance.log) |
| `test-settings-app` | 19 window/activation groups | [Results](window-regression/results.json) |
| `test-preferences` | 24 preference/theme/persistence groups | [Results](preferences-regression/metadata.json) |
| `test-settings-boundary` | 9 transport/isolation groups | [Results](boundary/result.json) |
| `test-settings-lifecycle` | 10 compact-flyout/owner groups | [Results](flyout-regression/results.json) |

The S3 suite uses independent protocol peers and actual pointer/keyboard input.
It verifies full-size UTF-8 transfer, empty/invalid drafts, digest/offset rejection,
CAS and nonce deduplication, field preservation, normal dialogs and preview,
invalid-JSON navigation/close/reopen, atomic save, save/export failures, three-way
merge, a newer equal-text draft during slow Apply, lock denial, explicit Discard,
backend restart, local recovery navigation and light/native/narrow presentation.
Pure tests inject failures at every allocation in shared draft retention/merge.

Reproduce the S3 suite with:

```sh
ZIG_GLOBAL_CACHE_DIR=/home/zoey/Pearl/.cache/zig zig build test-settings-appearance -Doptimize=ReleaseSafe -- --output artifacts/settings-app/s3/final-acceptance
```

Other integration targets accept the same `-- --output DIRECTORY` convention.
Use separate output directories; S1/S2 approved evidence is retained separately.

## Actual window captures

- [Appearance, dark](final-acceptance/session/appearance-real-dark.png)
- [Wallpaper draft preview](final-acceptance/session/appearance-wallpaper-preview.png)
- [Appearance, light](final-acceptance/session/appearance-real-static.png)
- [Appearance, native GTK](final-acceptance/session/appearance-real-gtk.png)
- [480-pixel window, 24-pixel text](final-acceptance/session/appearance-real-narrow-large-text.png)
- [Invalid Advanced JSON retained after reopen](final-acceptance/session/advanced-invalid-retained.png)
- [Advanced conflict](final-acceptance/session/advanced-conflict.png)
- [Close after backend loss](final-acceptance/session/unavailable-close-retention.png)

These are real editor captures, not synthetic S2 sample data. The complete field
inventory makes Appearance longer than the illustrative reference; it stays in
one page viewport with fixed heading/footer. The sidebar/category structure,
normal window chrome, cards and Material/native theme behavior remain shared
with S2. The full scale/output comparison matrix remains the S6 gate.

## Scope and limits

S4 service pages and Aqueous editing remain unavailable. S5 owns desktop packaging,
CLI cutover and flyout handoff. The approved compact flyout routing and bar keyboard
mode `none` remain intact; no standalone layer-shell surface or duplicate service
agent was added.

Acknowledged drafts live in backend memory, not on disk. Backend exit loses that
shared memory; an open frontend retains a recovery candidate. A frontend crash
cannot recover changes it never transferred. The accepted operation ledger holds
64 pending/recent receipts for at least ten minutes; exhaustion reports Busy and
preserves local edits for a later retry.

See the [API contract](../../../docs/SETTINGS_FRONTEND_API.md) and
[preferences documentation](../../../docs/PREFERENCES.md). S4 requires the user's
next approval.
