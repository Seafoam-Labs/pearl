# M2: safe settings, provenance and workspace trust

**Historical M2 policy increment: implemented and validated; M2 implementation is COMPLETE for the bounded workspace preview.** See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md). This increment follows workspace discovery/search in the standard plan. Its no-executable-consumer statements describe M2, not current M3: [bounded language services](WORKBENCH_M3_LANGUAGE.md) are implemented and validated within bounded M3 and require exact trust **plus explicit Language: Start… confirmation**. Trust alone still starts nothing. The definitive [M3 gate](WORKBENCH_M3_LANGUAGE.md#final-validation-passed) passed after the queue/sync fix; **next is M4 Git/review, not started**.

## Safe repository settings

Four editor settings are supported in restricted and trusted workspaces:

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

A failed candidate keeps the previous workspace, settings and dirty documents while restricting trust and reporting the error. Missing `.coral`/`settings.json` means no folder override. Malformed, unreadable, symlinked or nonregular settings do not silently become defaults. Permission/I/O-denied roots reject the candidate when their folder policy cannot be classified safely; missing/non-directory roots remain explicit unavailable entries.

Folder settings have **64 KiB/source**, **32 language entries**, and **64-byte language IDs**; at most 32 roots means 2 MiB aggregate folder source. The manifest retains its 1 MiB document limit. Unknown/executable keys, decoded duplicate fields, unsupported versions, explicit nulls and invalid UTF-8/NUL fail closed. Traversal is descriptor-relative without following symlinks; execute-only ancestors are supported, while the final settings file must be readable. File checks/read consistency are snapshots, not atomic filesystem isolation.

No new recursive settings watcher is installed. Existing explorer/manifest notifications invalidate authority; explicit Rescan remains the adoption mechanism for folder changes outside watch coverage. Trust workers reread policy before persistence/restoration and after store access, rejecting a mismatch with the published model.

## Persistent, explicit trust

Unfamiliar workspaces start **restricted**. Reading, browsing, searching, editing and explicit saves remain available without trust. The delivered [Explorer file operations](WORKBENCH_M2_OPERATIONS.md) are also permitted as explicit local edits: input → worker preparation → review confirmation for every kind, including creation, with no writes before confirmation. They do not launch hooks, tools, LSP or agents, promote trust, or grant reusable execution permission. M3 may send static filtered did-file notifications to already explicitly started language sessions after successful operations; that is not server startup or a will-operation command.

Explorer file-operation admission independently refuses all affected open documents (clean or dirty across live/draining windows), pending loads/choosers/saves/sessions/recovery, and changes affecting peer/nested roots or active manifests. **Any unavailable root or lexical `..` in any open process workspace's root/manifest blocks all mutations with `WorkspaceBusy`**, even outside that workspace. Close the affected workspace or reopen verified available normalized/canonical paths; do not blindly collapse `..`. Trust approval cannot bypass these checks. Reviewed root-list/Save As manifest edits are a separate operation with [their own source-byte/etag and open-manifest checks](WORKBENCH_M2_PROJECTS.md#reviewed-workspace-root-management); unlike Explorer mutations, they preserve supported lexical `..`/unavailable roots without deleting or moving those paths. Descriptor/metadata revalidation remains best-effort against final external rename/source races, not a sandbox, content hash or fsync guarantee.

- **Trust workspace…** opens a real confirmation dialog listing the exact scope. Cancel changes nothing. A repository cannot approve itself.
- Successful approval persists only after worker-side scope/policy revalidation and a durable store write.
- **Workspace: Revoke trust** immediately restricts the current policy and invalidates its permits/pending gate, then serializes persistent removal.
- **Recheck** validates current identity and the machine store. Failed initial restoration requires fresh explicit approval after the failure is resolved.

**Trust is a precondition, not permission for every action.** This historical M2 increment enabled no LSP, task runner, debugger, hook executor, extension host or agent tool; its tests exercised a pending permit, never a real command. **M3 now consumes generation-checked LSP permits**, with separate explicit Start confirmation, user-owned executable configuration, fresh checks before approvals and cancellation when authority changes. The server has user permissions, not an OS sandbox; same-root navigation/review checks do not confine its filesystem or network access. Other executable services remain future work. See [M3 startup/configuration and limits](WORKBENCH_M3_LANGUAGE.md).

### Exact scope identity

Approval binds:

- Ordered roots and their lexical/canonical paths.
- The supplied manifest base, preserving relative-root semantics through symlinks.
- Directory device/inode **and birth time** for roots and manifest base.
- A versioned digest of repository settings/excludes/paths, safe user values and actual key presence, built-in defaults and precedence semantics.

There are no recursive parent grants. Unavailable roots cannot be approved. Root replacement, root-list changes or effective-policy changes do not inherit current authority. Safe user preference changes conservatively invalidate trust even if a repository override masks the value.

Birth time is required via Linux `STATX_BTIME`. Filesystems that cannot provide it report **UnsupportedBirthTime** and remain restricted; there is no weaker inode-only fallback. Fingerprint domain v2 rejects prior inode-only approvals. Birth time closes ordinary inode-reuse mistakes but is still filesystem-reported snapshot identity, not an inode lease or protection against a malicious same-UID actor.

A new application instance may restore a valid exact approval. During an instance's lifetime, continuity anchors survive Rescan and close/reopen: encountering a different fingerprint requires fresh approval even if that alternate identity already has a stored approval. An old confirmation or worker completion cannot grant against a newer model/user/settings generation. Stale approvals that reached disk are queued for serialized removal.

### Machine store and failures

The store is **`$XDG_STATE_HOME/coral/trust/store`**, normally `~/.local/state/coral/trust/store`. It is a bounded versioned/checksummed binary record store, not editable workspace JSON.

- Maximum **256 records / 1 MiB input**.
- `coral` and `trust` directories must be owner-private **0700**; store files must be owner-owned, singly linked regular files with **0600** permissions.
- State-path traversal rejects symlinks and unsafe writable ancestors. The configured state-home ancestry must already exist; Coral creates its private children, not arbitrary missing machine-state ancestors.
- The authority store must be outside the workspace roots and manifest base. Broad workspaces encompassing the state store remain restricted.
- Nonblocking advisory locks serialize writers; each writer rereads/merges to avoid clobbering another approval. Contention reports Busy rather than waiting indefinitely.
- Replacement uses private temporary storage, file fsync, rename and directory fsync. Uncertain durability quarantines the store with an `uncertain` marker; it does not silently restore trust.
- Missing records mean restricted. Corruption, unsafe files/modes, unsupported identity, lock errors and write failures remain restricted with visible errors.

A failed revoke remains sticky locally across same-scope model replacements/rechecks; it is not silently cleared by an old disk approval. **If persistence fails, an old approval can still exist on disk and another process/restart may see it.** Resolve the reported storage issue and retry Revoke. Do not treat closing the dialog as successful durable revocation. Other running instances observe removal only when they revalidate; cross-process instantaneous cancellation is not implemented. Quarantine repair is explicit machine-state maintenance, not an automatic deletion of uncertain data.

With [multi-window support](WORKBENCH_M2_WINDOWS.md), explicit revoke synchronously restricts every matching lexical workspace scope in this process before persistence. Up to 256 non-evicted generation markers prevent newly opened windows from reviving an old approval after pending/failed removal, even after the original owner closes; saturation fails closed. Fresh approval acknowledges the generation only for its owner. Scope/key associations for queued removals survive owner closure, and approval waits for matching cleanup to drain so delayed removal cannot erase a fresh grant. This does not provide cross-process revocation notification or enable executable features.

## Ownership and bounds

One policy worker runs at a time, with one coalesced recheck. Revocation queues, local scope restrictions, known approvals and continuity records are each capped at 256; saturation fails closed. Inputs and safe-user snapshots are owned/immutable. Model/request/policy generations guard callbacks. Pending revocations are serialized behind an in-flight approval, and worker holds remain until cleanup after window close.

Filesystem calls can still block on an unresponsive mount. Cancellation invalidates authority immediately but cannot forcibly interrupt every syscall. These controls protect against stale application operations and unsafe configuration; they are not an OS sandbox or universal tool approval.

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

## M2 closure and remaining boundaries

[Explicit workspace sessions](WORKBENCH_M2_SESSIONS.md), [native dock/picker integration](WORKBENCH_M2_DOCKS.md), [multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) and [bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) were implemented in M2 without enabling executable consumers. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The policy gate again passed 17 native groups and executed 191 widget tests; the policy validation above remains historical evidence. [Automatic projects, native recents/buffer pickers and reviewed root management](WORKBENCH_M2_PROJECTS.md) now complete mandatory M2 scope. Automatic restoration rereads current settings and independently revalidates trust; it never imports an approval from saved text. Reviewed root edits preserve semantic settings/language overrides/excludes, then reload through the normal policy pipeline; root/policy changes do not confer authority. Those passes remain historical M2 evidence. Bounded M3 LSP is now implemented and validated: COMPLETE. **Next is M4 Git/review, not started**; agents remain later milestones. The [M3 validation report](WORKBENCH_M3_LANGUAGE.md#final-validation-passed) separates the definitive frozen-source aggregate/production pass from earlier failures and pre-queue-fix visual evidence, and claims harness reaping assertions rather than an unperformed final baseline cleanup scan. M3 text edits are reviewed grouped undo without autosave; single reviewed resource operations mutate disk with no undo. This does not weaken the M2 trust/storage boundaries above.
