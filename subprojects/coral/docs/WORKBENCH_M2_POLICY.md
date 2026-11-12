# M2: safe settings, provenance and always-trusted workspaces

**Historical M2 policy increment: implemented and validated; M2 implementation is COMPLETE for the bounded workspace preview. By explicit user request the workspace consent boundary was later removed: workspaces are ALWAYS trusted, with no confirmation or revocation prompts and no consent state. Stale-generation invalidation remains; this is NOT an OS sandbox.** See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md). This increment follows workspace discovery/search in the standard plan. Its no-executable-consumer statements describe M2, not the current workbench: [bounded language services](WORKBENCH_M3_LANGUAGE.md) implement detected-language automatic startup after open/restore/save/language changes, requiring **exact prior server approval** in an unpaused workspace (workspace trust is automatic). A new/changed key gets one first-use prompt; automatic trust does not itself grant server approval. Stop persists a workspace pause; Start/Restart resumes with fresh checks. Git keeps its per-window subprocess disclosure and destructive-mutation reviews. The [historical M3 gate](WORKBENCH_M3_LANGUAGE.md#final-validation-passed) passed after the queue/sync fix, before the automatic increment; [automatic-increment validation is separately accepted](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted). M4 Git/review and M5 terminal/tasks are implemented; the trust-boundary removal increment passed targeted policy validation (17/17 native groups), with docks/session/widgets/production/visual pending the parent aggregate.

## Safe repository settings

Four editor settings are supported in all workspaces (workspaces are always trusted):

| Key | Type / range | Built-in default |
| --- | --- | --- |
| `lines` | boolean | `true` |
| `wrap` | boolean | `true` |
| `spaces` | boolean | `true` |
| `indent` | integer, 1–8 | `4` |

Workspace values live in the existing version-1 manifest:

```json
{
  "version": 1,
  "roots": [{"name": "App", "path": "./app"}],
  "settings": {
    "wrap": false,
    "indent": 2,
    "languages": {
      "zig": {"indent": 4}
    }
  }
}
```

Folder values live in **each root's `.coral/settings.json`**, including folders opened without a manifest:

```json
{
  "version": 1,
  "settings": {
    "indent": 8,
    "languages": {
      "zig": {"indent": 2, "spaces": true}
    }
  }
}
```

Language keys are GtkSourceView language IDs, not filename globs or spelling dictionaries. Only the four safe keys are permitted inside a language patch. There is no user-language configuration schema in this M2 settings increment. M3 separately adds user-owned `~/.config/coral/languages.json` for server argv/environment, not repository editor overrides.

### Precedence and provenance

Per key, resolve in this order; later supplied values win:

1. Built-in default.
2. Explicit user key in existing `preferences.ini`.
3. Workspace general settings.
4. Folder general settings for the owning root.
5. Workspace language override.
6. Folder language override.

An explicit user value equal to the default is still reported as **user**, not default. Missing keys inherit; `null` is not a reset instruction and is rejected. In the examples above, Zig indentation is **2**, from `folder_language`; another language uses folder indentation **8**.

Choose **Workspace: Settings and Trust…** from the menu or command palette to inspect effective values, per-key origins, root/language context, exact trust scope and errors. Normal views, duplicate views and editable excerpts receive the same per-document settings. The logical language remains selected when large-file/long-line policy detaches its syntax parser, so presentation limits do not silently remove language overrides.

Scratch documents and files outside the workspace use only defaults/user preferences. Repository values are never saved into the user preferences file. Existing theme, font size, spelling enablement and dictionary preferences stay user-owned and are not accepted from repository settings. User preference writes run on a bounded asynchronous path with application lifetime holds.

### Loading and refreshing

Opening a workspace reads settings on workers. **Workspace: Rescan** refreshes the manifest and all root settings; this also works for a folder-only workspace. Recheck in the trust dialog validates the current policy snapshot but does **not** adopt changed settings—use Rescan for that.

A failed candidate keeps the previous workspace, settings and dirty documents and reports the error. Identity-capture health may show `failed`, but the workspace stays trusted; stale permits/results are still invalidated. Missing `.coral`/`settings.json` means no folder override. Malformed, unreadable, symlinked or nonregular settings do not silently become defaults. Permission/I/O-denied roots reject the candidate when their folder policy cannot be classified safely; missing/non-directory roots remain explicit unavailable entries.

Folder settings have **64 KiB/source**, **32 language entries**, and **64-byte language IDs**; at most 32 roots means 2 MiB aggregate folder source. The manifest retains its 1 MiB document limit. Unknown/executable keys, decoded duplicate fields, unsupported versions, explicit nulls and invalid UTF-8/NUL fail closed. Traversal is descriptor-relative without following symlinks; execute-only ancestors are supported, while the final settings file must be readable. File checks/read consistency are snapshots, not atomic filesystem isolation.

No new recursive settings watcher is installed. Existing explorer/manifest notifications invalidate authority; explicit Rescan remains the adoption mechanism for folder changes outside watch coverage. Policy workers reread policy and recapture identity, rejecting a mismatch with the published model (stale-generation invalidation); no consent state is persisted or restored.

## Always-trusted workspaces (consent boundary removed)

**By explicit user request, restricted mode and the workspace consent boundary
were removed. Workspaces are always trusted:** there is no trust confirmation
dialog, no revocation prompt, no restricted-mode gate and no consent state read
or written. Opening a workspace immediately enables the executable surfaces
(terminal, tasks, approved language servers, disclosed Git) with the user's
permissions.

**Security tradeoff (explicit):** a malicious or unfamiliar repository no longer
has a per-workspace consent gate before its task definitions can be run or its
configured language servers can start. Repository-supplied `.coral/tasks.json`
commands execute when the user runs them; approved servers have user
filesystem/network access. The remaining protections — stale-generation
invalidation, manager-wide file barriers, guardTree, bounded supervised capture,
the safe terminal OSC policy, Git's subprocess disclosure and mutation reviews,
and language's exact server approval — are application-level admission controls,
**not an OS sandbox**. The user requested and accepted this tradeoff.

What the commands do now:

- **Trust workspace…** reports “Workspaces are always trusted; no approval is
  required.” and opens no dialog.
- **Workspace: Revoke trust** retires outstanding permits so stale work cannot
  continue, and reports that revocation is unavailable. It cannot untrust a
  workspace and writes no removal state.
- **Workspace: Settings and Trust…** still shows effective settings, per-key
  provenance and identity diagnostics; its trust button stays insensitive.
  **Recheck** still invalidates and recaptures current identity.

Reading, browsing, searching, editing and explicit saves were always available;
they remain so. The delivered [Explorer file operations](WORKBENCH_M2_OPERATIONS.md)
remain explicit local edits: input → worker preparation → review confirmation for
every kind, including creation, with no writes before confirmation. They do not
launch hooks, tools, LSP or agents. Automatic workspace trust does not bypass
their review or admission checks. M3 may send static filtered did-file
notifications to already approved, running language sessions after successful
operations; that is not server startup or a will-operation command.

Explorer file-operation admission independently refuses all affected open
documents (clean or dirty across live/draining windows), pending
loads/choosers/saves/sessions/recovery, and changes affecting peer/nested roots or
active manifests. **Any unavailable root or lexical `..` in any open process
workspace's root/manifest blocks all mutations with `WorkspaceBusy`**, even
outside that workspace. Close the affected workspace or reopen verified available
normalized/canonical paths; do not blindly collapse `..`. Reviewed root-list/Save
As manifest edits are a separate operation with [their own source-byte/etag and
open-manifest checks](WORKBENCH_M2_PROJECTS.md#reviewed-workspace-root-management);
unlike Explorer mutations, they preserve supported lexical `..`/unavailable roots
without deleting or moving those paths. Descriptor/metadata revalidation remains
best-effort against final external rename/source races, not a sandbox, content
hash or fsync guarantee.

**Trust is a precondition, not permission for every action.** Executable services
still obtain generation-checked capability permits; only stale scope/generation
can refuse them now. **M3 consumes generation-checked LSP permits** with separate
exact server approval (one first-use review for a new/changed key), user-owned
executable configuration, fresh checks before launch/approval and cancellation
when authority changes. Unchanged approved servers may start automatically in
unpaused workspaces. Lifecycle approval/pause keys live in separate machine state
under `coral/language`; storage errors fail closed. Stop persistence retries
`Busy` with a capped delay and retains intent, but nonretryable failure can only
retain/report a local inhibit, not promise durability. The server has user
permissions, not an OS sandbox; same-root navigation/review checks do not confine
its filesystem or network access. **Git keeps its per-window subprocess
disclosure and per-operation destructive-mutation reviews; M5 terminal sessions
spawn on user action with no disclosure, and task runs are explicit user commands
holding the manager-wide file barrier with guardTree.** See
[M3 startup/configuration and limits](WORKBENCH_M3_LANGUAGE.md) and the
[M5 guide](WORKBENCH_M5_TERMINAL.md).

### Exact scope identity

Identity capture is retained for **stale-generation invalidation and
diagnostics, not consent**. It binds:

- Ordered roots and their lexical/canonical paths.
- The supplied manifest base, preserving relative-root semantics through symlinks.
- Directory device/inode **and birth time** for roots and manifest base.
- A versioned digest of repository settings/excludes/paths, safe user values and actual key presence, built-in defaults and precedence semantics.

There are no recursive parent grants. Root replacement, root-list changes or
effective-policy changes invalidate outstanding permits and stale results even
though the workspace stays trusted. Safe user preference changes conservatively
invalidate permits even if a repository override masks the value.

Birth time is required via Linux `STATX_BTIME`. Filesystems that cannot provide it report **UnsupportedBirthTime**: identity capture fails visibly (status `failed`), but the workspace stays trusted and permits still issue; there is no weaker inode-only fallback. Fingerprint domain v2 rejects prior inode-only approvals. Birth time closes ordinary inode-reuse mistakes but is still filesystem-reported snapshot identity, not an inode lease or protection against a malicious same-UID actor.

Identity capture runs on open, Rescan and close/reopen. Encountering a different
fingerprint invalidates outstanding permits and stale results; there is no
approval to restore or refresh. An old worker completion cannot apply against a
newer model/user/settings generation. No consent state is queued for removal
because none is written.

### Machine store and failures (historical consent machinery)

**The consent store is no longer read or written for trust decisions.** The state
home **`$XDG_STATE_HOME/coral/trust`** (normally `~/.local/state/coral/trust`)
now serves identity diagnostics only; the settings dialog states this explicitly.
The bounded versioned/checksummed binary record store below is the removed
consent machinery, retained as history:

The historical store was **`$XDG_STATE_HOME/coral/trust/store`**, a bounded versioned/checksummed binary record store, not editable workspace JSON. It enforced:

- Maximum **256 records / 1 MiB input**.
- `coral` and `trust` directories must be owner-private **0700**; store files must be owner-owned, singly linked regular files with **0600** permissions.
- State-path traversal rejects symlinks and unsafe writable ancestors. The configured state-home ancestry must already exist; Coral creates its private children, not arbitrary missing machine-state ancestors.
- The authority store must be outside the workspace roots and manifest base. Broad workspaces encompassing the state store remain restricted.
- Nonblocking advisory locks serialize writers; each writer rereads/merges to avoid clobbering another approval. Contention reports Busy rather than waiting indefinitely.
- Replacement uses private temporary storage, file fsync, rename and directory fsync. Uncertain durability quarantines the store with an `uncertain` marker; it does not silently restore trust.
- Missing records mean restricted. Corruption, unsafe files/modes, unsupported identity, lock errors and write failures remain restricted with visible errors.

None of these consent-state rules gate execution anymore: identity-capture
errors are reported visibly while the workspace stays trusted, and no approval,
quarantine or removal state is created.

Historically, a failed revoke remained sticky locally across same-scope model replacements/rechecks; it was not silently cleared by an old disk approval. If persistence failed, an old approval could still exist on disk and another process/restart could see it. Other running instances observed removal only when they revalidated; cross-process instantaneous cancellation was not implemented. Quarantine repair was explicit machine-state maintenance, not an automatic deletion of uncertain data.

With [multi-window support](WORKBENCH_M2_WINDOWS.md), the manager protocol
remains (scope generations, invalidate-on-revoke), but there is no consent state
to remove: cleanup is never pending and queued/failed revokes are always zero.
**Workspace: Revoke trust** retires permits in every matching window
synchronously; it cannot untrust a workspace. The historical 256 non-evicted
generation markers, queued-removal draining and fresh-approval rules applied to
the removed consent store; stale-generation checks still prevent a new window
from using retired permits.

## Ownership and bounds

One policy (identity-capture) worker runs at a time, with one coalesced recheck. Inputs and safe-user snapshots are owned/immutable. Model/request/policy generations guard callbacks and retire stale permits/results. Worker holds remain until cleanup after window close. The historical 256-entry revocation/approval/continuity caps applied to the removed consent machinery; no consent queues exist now.

Filesystem calls can still block on an unresponsive mount. Cancellation invalidates permits immediately but cannot forcibly interrupt every syscall. These controls protect against stale application operations and unsafe configuration; they are not an OS sandbox or universal tool approval.

## Source and validation

| Area | Files |
| --- | --- |
| Strict settings schema and resolution | `src/workspace/settings.zig`, `settings_test.zig`, `manifest.zig` |
| Descriptor-relative folder settings/model | `settings_fs.zig`, `model.zig`, `model_test.zig` |
| User-key presence and persistence | `src/platform/settings.zig` |
| Logical language and actual view settings | `src/document.zig`, `src/app.zig` |
| Trust identity, records and permit generations | `src/workspace/trust.zig`, `trust_test.zig` |
| Machine-store filesystem boundary | `src/workspace/trust_fs.zig` |
| Native dialogs, worker/controller integration | `src/workspace/policy_controller.zig`, `controller.zig`, `src/app.zig`, `src/workbench/commands.zig` |
| Private native acceptance | `tests/policy.py` |

From `subprojects/coral`:

```sh
zig build test-m2-policy -Doptimize=safe -j1 --summary all
# Native acceptance only:
zig build policy -Doptimize=safe -j1
```

Validation on **Zig 0.17.1**, 2026-11-09:

- **264 headless-root tests passed**; separate trust target **24 passed / 1 skipped**. The skip needs root for foreign-owner checks. Trust fork/concurrent-writer tests run in a separate process from the GIO worker tests. The separate appearance suite also passed (cached on the final run).
- **180 widget tests passed**.
- **17 native settings/trust groups passed**, with 168 fixture-hash checks and 34 absent executable sentinels. Coverage includes precedence/provenance, actual full/duplicate/excerpt GTK properties, long-line language retention, user-preference isolation/persistence, malformed/FIFO/symlink policy rejection, explicit confirmation/cancel, restart restore, revoke/failure, exact identities, previously approved alternate incarnations, stale before/after-write delivery, and delayed shutdown.
- Existing gates passed: M1 native 40 / groups 14 / recovery 13; workspace 18; explorer 19; search 9. An execute-only-ancestor regression found by the workspace suite was fixed with `O_PATH` traversal and new unprivileged settings/trust tests; the failing gate and policy aggregate were rerun successfully.
- Production safe build with hooks disabled, Zig formatting, Python compilation and whitespace checks passed.

Latest delayed-shutdown fixture acknowledged input in about **25 ms** and closed its window in about **116 ms**, before the worker exited successfully. These are handler/lifecycle measurements, not paint latency or remote-mount guarantees. Fault injection tests do not establish real power-loss durability.

Evidence: `pearl/.cache/coral-policy/results.json`, adjacent screenshots/session logs, and `pearl/.cache/coral-policy-validation-logs/`. All native fixtures use private Wayland, HOME and XDG state. No user workspace was trusted, no packages installed, and no commits created by this work.

**Trust-boundary removal increment (targeted):** native policy **17/17 groups
passed** with the consent boundary removed, including `always_trusted_no_consent`
(no consent dialog opens, no consent state is written, revoke retires stale
permits without untrusting, Recheck remains available) and the stale
worker/delivery invalidation cases. Evidence:
[log](../../../.cache/coral-m5b-policy.log),
[results](../.cache/m5b-policy/results.json). Docks, session-unit, widgets,
hooks-disabled production and visual were **not rerun** for this increment and
are pending the parent aggregate; the terminal/tasks surfaces of the same
increment passed 12/12 and 7/7 (see the [M5 guide](WORKBENCH_M5_TERMINAL.md)).
The historical counts above remain M2 evidence.

## M2 closure and remaining boundaries

[Explicit workspace sessions](WORKBENCH_M2_SESSIONS.md), [native dock/picker integration](WORKBENCH_M2_DOCKS.md), [multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) and [bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) were implemented in M2 without enabling executable consumers. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The policy gate again passed 17 native groups and executed 191 widget tests; the policy validation above remains historical evidence. [Automatic projects, native recents/buffer pickers and reviewed root management](WORKBENCH_M2_PROJECTS.md) now complete mandatory M2 scope. Automatic restoration rereads current settings and recaptures identity; it never imports consent state from saved text (none exists). Reviewed root edits preserve semantic settings/language overrides/excludes, then reload through the normal policy pipeline; root/policy changes invalidate stale permits but do not untrust the workspace. Those passes remain historical M2 evidence. The bounded M3 baseline has historical validation; automatic startup is implemented with separately accepted validation. M4 Git/review and M5 terminal/tasks are implemented; agents remain later milestones. The [M3 validation report](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted) separates accepted automatic-increment results from the historical frozen-source aggregate/production pass, earlier failures and pre-queue-fix visual evidence, and claims harness reaping assertions rather than an unperformed final baseline cleanup scan. M3 text edits are reviewed grouped undo without autosave; single reviewed resource operations mutate disk with no undo. The later consent-boundary removal is a separate, user-requested change recorded above; the settings/provenance and file-operation admission boundaries remain.
