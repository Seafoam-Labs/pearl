# M2: native multi-window lifecycle

**Implemented:** multiple native Coral windows in one process, with independent documents/workspaces/docks and explicit, bounded lifecycle ownership. This does not add shared cross-window buffers, tab dragging, automatic window-session restoration, LSP, Git or agents. M2 remains a bounded workbench preview.

## Use

| Command | Shortcut / behavior |
| --- | --- |
| New Window | **Ctrl+Shift+N**; new empty window using current user preferences |
| Close Window | **Ctrl+Shift+W** or native window close; resolves this window's dirty documents |
| Next Window / Previous Window | Command palette/menu; cycles live windows in creation order |
| Quit All | **Ctrl+Q**; resolves windows sequentially, starting with the requester |
| New document / Close tab | **Ctrl+N / Ctrl+W**; existing document behavior |

**Behavior change:** Ctrl+Q now means **Quit All**, not just closing the current window. Use Close Window to leave siblings running. Closing the last document retains the existing behavior of closing its window.

Quit All prompts one window at a time. Save/Discard resolves its documents; Cancel or a save/conflict failure stops the quit chain. Already resolved/closed windows are not reopened—this is not an atomic all-window transaction. New Window is refused while Quit All is in progress. Existing modal/startup recovery work must be finished before its window can be closed; refusal cancels aggregate quitting rather than leaving it stuck.

The limit is **16 live plus closing/draining windows**. Closed entries are reclaimed after callbacks finish, so repeated create/close cycles reuse capacity. IDs are monotonic and not reused. A slow filesystem operation can temporarily consume a closing slot; blocking mount I/O is still not forcibly interruptible.

CLI file/folder/workspace arguments apply to the **first window only**. New windows do not repeat them. Coral remains `G_APPLICATION_NON_UNIQUE`: a separate CLI invocation starts a separate process, not an IPC request to an existing window. There is no new `--new-window` forwarding protocol.

## Ownership and commands

`src/application.zig` replaces the singleton App/recovery owner with a stable registry. Every window owns its documents, editor groups/history, browser/watchers, search, policy controller, docks, palette and recovery journal. Menus, Explorer/dock buttons and actions use **`win.*`**, so changing focus cannot retarget a pending operation to another App.

Every asynchronous file operation, chooser, search/browser/policy/session worker retains its originating App. Recovery maintains its own tracked holds. Closing removes the native window immediately, shuts down/cancels services and disables UI application of late results, but retains its widget tree until both ownership domains drain. The registry frees it on a later main-loop turn, not within a releasing callback. The last window waits for holds and preference persistence before process exit.

Palettes and dialogs stay attached to their owner. Palette teardown retains its GTK window through the owner-close callback, including externally initiated Quit All. Tests cover retained callbacks, sibling responsiveness and repeated reclamation; this is not a claim of exhaustive allocation-leak proof.

## Same file in two windows

Documents are canonical/deduplicated **within a window**, not shared between windows. Opening a path in A and B creates independent buffers and edit histories. An unsaved change in A is not an overlay in B's Search. File monitoring and saved etags expose disk changes; saving an older copy requires the existing conflict decision. A missing saved etag cannot silently authorize an unchecked ordinary Save.

A process-wide reservation table allows at most **16 in-flight saves**, using the existing canonical destination spelling (at most 4,095 bytes). Normal Save, Save As and explicit overwrite reserve the destination through completion. A concurrent save to that destination is rejected, not queued, and retains its dirty buffer and old etag. Cancellation/failure releases the reservation only during completion cleanup; retry after the first save still performs the usual conflict checks.

This coordinates **this process only**. It is not an atomic filesystem compare-and-swap against other processes or external rename/symlink races. Explicit overwrite and Save As retain their existing user-authorized replacement behavior.

## Process-wide workspace file operations

[Explorer file operations](WORKBENCH_M2_OPERATIONS.md) now provide explicitly reviewed create/rename/move/permanent-delete actions. Their manager checks include **live and closing/draining owners**. All affected open file-backed documents block admission, **clean as well as dirty**, including descendants of affected directories and destination paths. Resolve edits by saving or explicitly discarding as needed, then close the documents in **every** window and wait for cleanup; merely saving a still-open clean document is insufficient. No open-document rebinding or LSP events are implemented.

Pending loads/load decisions, file/workspace choosers, saves/reservations, session work, recovery decisions/claims and competing dialogs also block admission. Peer/nested workspace roots and active manifests are protected. **Any unavailable root or lexical `..` root/manifest in any open process workspace blocks all mutations with `WorkspaceBusy`, even in an unrelated window.** Close the affected workspace or reopen verified available normalized/canonical paths. Do not blindly collapse `..`: symlink traversal can change the intended location.

Accepted confirmation acquires one process-wide apply barrier, released at completion callback—not at worker return. It refuses competing mutations, opens/reloads, saves/Save As, session save/restore, workspace switches/close and New Window. Existing unaffected buffers remain editable. Normal Close Window/Quit All refuses an active operation and cancels aggregate quitting rather than abandoning its owner; finish/cancel the operation and wait for worker cleanup. Application holds retain cancelled/prepared work until descriptor retirement and callback delivery. Stale workspace state fails safely; successful mutation is not relabelled cancelled if cancellation races completion.

Success rescans current Explorer and invalidates Search for explicit Refresh; created files do not auto-open. This barrier coordinates only this process. Retained source/root/parent descriptors and metadata are rechecked before mutation, but final external parent/source rename races cannot be fully prevented by Linux fd-based checks. This is best-effort containment, not a sandbox, content-hash guarantee or fsync durability promise.

## Shared preferences and appearance

Only user preferences are broadcast to live windows; each window reapplies its own workspace/folder/language overrides. Repository settings never become user defaults. Persistence has one running write and one latest pending snapshot, avoiding racing preference writers within the process. New windows inherit the current user layer.

Custom palette and editor-font CSS are scoped to unique window classes, also applied to owned separately rooted dialogs. Closing one owner cannot remove another's provider. Native GTK editor text sizing works without requiring the custom-theme `.coral` class.

**Native named GTK themes remain display-wide.** One reference-counted provider uses the last applied named theme/variant. Closing a follower does not remove/revert it while another follower remains; releasing the final follower restores the normal display theme. User theme preferences are shared, not per-window theme presets. Physical IME and screen-reader qualification remain separate manual work.

## Trust coordination

Explicit revoke synchronously invalidates all matching **lexical workspace scopes in this process**, before asynchronous removal starts. Existing gates and confirmations are invalidated; all six capability permits remain unavailable until a valid fresh approval. Unrelated scopes are not broadcast to. No executable consumers are introduced by this change.

The manager retains up to **256 non-evicted revocation-generation markers**. New windows cannot regain an old disk approval while removal is pending or failed, even after the revoking window closes. Saturation fails closed rather than forgetting revocations. Fresh explicit approval acknowledges the current generation for that owner, not automatically for its peers.

Scope/key associations are retained for queued and active removals, including a never-trusted owner's identity-only removal. Fresh approval waits until matching cleanup drains—even if the owner has closed—so an old delayed removal cannot erase the new grant. Nonblocking store-lock contention can still produce visible `Busy` errors; local restriction remains effective. A failed removal may persist on disk across process exit. Cross-process revocation notification is not provided.

## Recovery and saved sessions

Each window gets an independent journal. Only the first window discovers interrupted sessions; creating another window never reoffers candidates already kept for later. Later journals open on workers while the window remains usable. Initialization failures remain visible, with no insecure fallback. A crash can leave multiple journals; startup retains the existing explicit restore/keep/discard sequence and restores documents as unsaved copies, not a reconstructed arrangement of windows.

**Save/Restore Workspace Session still uses one explicit shared slot.** In-process admission permits one session operation at a time; another window receives `Busy`, preserving the current operation. Sequential explicit saves replace the slot. Restore acts only on the requesting window and keeps its existing documents. This is not a per-window session database or automatic startup/quit persistence. Dock/session schema v2 and crash-recovery formats are unchanged.

## Source and validation

| Area | Files |
| --- | --- |
| Registry, quit coordination, save reservations, shared prefs/revocation | `src/application.zig` |
| Window/App ownership, local actions and callback holds | `src/main.zig`, `src/app.zig`, `src/workbench/commands.zig` |
| Theme scopes and named-provider lifetime | `src/appearance.zig` |
| Recovery and worker ownership | `src/workspace/recovery_controller.zig`, `controller.zig`, `search_controller.zig`, `session_controller.zig`, `policy_controller.zig` |
| Palette teardown | `src/workbench/palette.zig` |
| Native acceptance | `tests/windows.py` |

From `subprojects/coral`:

```sh
zig build windows -Doptimize=safe -j1
zig build test-m2-windows -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all
```

**Historical multi-window-increment final validation on Zig 0.17.1:** all eight aggregate gates ran sequentially and passed: windows, M1, workspace slice, explorer, search, policy, sessions and docks, followed by a fresh hooks-disabled production compilation. Each command used `-Doptimize=safe -j1 --summary all` and a 600-second bound.

- **27 native multi-window cases**, using real keyboard/palette input, exported GTK window actions and actual chooser-button clicks—not only direct test dispatch.
- Coverage includes isolated documents/roots/groups/docks/search, close/quit cancellation, delayed worker/chooser/journal drains, 24 create/close cycles, the 16-window limit, same-file conflicts and save reservations, recovery discovery/crash restoration, shared sessions/preferences, scoped CSS and Native GTK sizing, same-scope revocation/failure inheritance, and delayed removal after owner closure.
- **191 widget-root tests** executed in every applicable final gate. The four direct headless runners were cached on that final rerun; earlier validation executed 270 main-root and seven appearance tests. Counts overlap and are not unique totals.
- Existing native gates: **40 workflows, 14 group/history, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions and 27 docks**, all passed.
- No GTK warnings/criticals, panics or protocol errors in the final window suite. The harness supplies byte-identical shipped styles in its private working directory, records hashes, and does not suppress warnings.

Evidence: `pearl/.cache/coral-windows/results.json`, adjacent logs/screenshots, and `pearl/.cache/coral-window-validation-logs/final-*.log`. Earlier review/fixture failures are retained separately. All fixtures use private Wayland/HOME/XDG directories and disposable files; no live desktop or user project was changed by validation.

## Remaining roadmap

Multi-window ownership and [bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) are delivered, not full IDE parity. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The window gate again passed 27 native cases and executed 191 widget tests; the counts above remain historical multi-window evidence. Next focused M2 work is remaining acceptance review, automatic/per-project workspace/session management and additional pickers. Cross-window tab transfer/shared buffers also remain unimplemented. LSP/Git/terminal/agent service milestones remain later work; M9 remains removed.
