# M4: first read-only Git slice

**M4 is in progress, not complete.** `src/git` implements explicit repository discovery,
status and bounded, noneditable staged/unstaged diff previews in a **separate native
Source Control window**. This is not the planned dock, editable Project Diff or full
Git/review engine. The next slice is safe staging with checked index/file snapshots.
See [current status](WORKBENCH_STATUS.md) and the [full M4 plan](WORKBENCH_IMPLEMENTATION_PLAN.md#8-zed-style-git-integration).

## Open Source Control

Use the **Git** menu or command palette (`Ctrl+Shift+P`):

| Command | Current behavior |
| --- | --- |
| **Git: Source Control…** | Review the subprocess disclosure, then open the window and discover repositories/read status; present the existing window without automatic refresh if already open. |
| **Git: Refresh repositories** | Explicitly rediscover roots and reload status; if not already approved/open, go through disclosure first. |
| **Git: Unstaged diff** | For the selected changed file, compare **index → disk**, not the editor buffer. |
| **Git: Staged diff** | For the selected changed file, compare **HEAD → index** (`git diff --cached`). |

First approve the workspace through **Workspace: Settings and Trust…**, then accept
**Continue with read-only Git** in the separate disclosure. Both are required.
There is **no Git execution at startup or in restricted mode**, and declining the
disclosure launches nothing. Approval is window-local and not persisted; closing
Source Control or invalidating its workspace/trust clears it. A peer editor window
must obtain its own approval. Root/trust changes and window shutdown cancel work;
workspace/request generations reject stale callbacks and owned processes are reaped.

The window has a repository/root picker, branch/HEAD/upstream/ahead/behind summary,
a paged changed-path list, Refresh, and Staged Diff / Unstaged Diff buttons. Each
row shows **index status then worktree status**, rather than separate staged and
unstaged trees. There are no default Git keyboard shortcuts. The preview is a
read-only text view, not an editable excerpt or split/word-diff surface.

## Discovery and supported repositories

- Probe each available **workspace root** and the **active saved file's parent**
  inside its owning root. There is no recursive scan of every nested directory.
  To discover a nested repository, open a file inside it and explicitly Refresh.
- Deduplicate repository top-level paths and retain at most **eight repositories
  per editor window**. The picker identifies the owning workspace root. Non-repo,
  bare or inaccessible candidates do not prevent other roots from being checked;
  skipped, failed and outside-root counts are reported.
- A discovered worktree top-level must be within its **owning workspace root**.
  Opening only a subdirectory of a larger enclosing repository does not authorize
  that outside-root repository; open the repository root instead.
- Resolve the top-level, absolute Git directory and common Git directory through
  Git, so **`.git` files and existing linked worktrees** are supported for discovery
  and reads. Git metadata can live outside the owning root. This is **not worktree
  creation, switching, removal or isolation**, nor a sandbox around metadata reads.
- **Unborn and detached HEAD** status is supported. An unborn repository can show
  its initial staged additions via `--cached`; no branch or commit is created.
- Status and diff use **`--ignore-submodules=all`**: no traversal or review of
  submodule contents, and a reported submodule entry gets an explicit non-text
  refusal. This is not a submodule-management feature.

## What the snapshot means

Status is parsed from `status --porcelain=v2 -z --branch`, with normal untracked
reporting. Paths are preserved as literal arguments, never interpolated into shell
commands. The parser accepts UTF-8 repository-relative paths and rejects malformed,
truncated, unsafe or over-budget input as a whole. **Invalid UTF-8 status paths are
refused**, not silently replaced or round-tripped through lossy labels. Controls,
bidi characters and backslashes are visibly escaped in bounded display labels;
display escaping does not change the raw Git argument.

Rename detection is **disabled** for both status and diff: renames appear as
**add/delete**, not a rename-aware review UI. The parser's support for rename/copy
records does not imply that the current command policy requests them.

Untracked paths are listed, but their contents are not read to fabricate diffs.
Unmerged/conflict entries get an explicit unsupported-preview message, not a
combined diff or conflict resolver. Binary and non-UTF-8 diffs get non-text notices.
Oversized captures/previews are refused rather than displayed as complete partial
results. A selected side with no change in the status snapshot asks for Refresh
if disk/index state has since changed.

**Refresh is manual.** There are no worktree/index/HEAD/config watchers or periodic
Git polling. Selecting a repository reads its status; requesting a diff reads that
side at that time. Status and subsequent diffs are **not an atomic snapshot with
external disk/index/HEAD changes**. A frozen, noneditable preview is not proof that
an external Git process has left the index unchanged.

The window shows a count of unsaved documents in its owning editor window; that
count updates on interaction, not continuously. **Unsaved buffers are excluded.**
No command here saves, stages or otherwise applies editor text, and no buffer-to-index
operation exists. Save explicitly through normal editor commands if you want disk
state to reflect your edits, then Refresh.

## Bounds and process policy

| Resource | Current bound |
| --- | --- |
| Discovered repositories | 8 per editor window |
| Status capture / parser input | 1 MiB; no parsing of incomplete captures |
| Status entries | 10,000; exceeding the limit refuses the snapshot |
| Status path / header value | 4,096 bytes each; discovery absolute paths are at most 4,095 bytes |
| Visible status rows | 128 per page, with Previous / Next controls |
| Version/discovery command capture | 16 KiB per command |
| Refresh capture budget | 4 MiB across discovery and initial status; repository selection or a diff request resets its budget to 1 MiB |
| Diff capture | 1 MiB, before the stricter text-preview checks |
| Text diff preview | 256 KiB, 4,000 lines, 2,048 bytes per line; no partial preview |
| Git job | One active job per controller; 15-second timeout per command, not a whole-refresh deadline |

Requires **Git 2.31+ at `/usr/bin/git`**; there is no PATH-based executable selection
or automatic installation. Zig submits fixed argv to the asynchronous process
supervisor, not a shell. `src/git/command.zig` defines the fixed policy:

- `--no-pager`, `--no-optional-locks`, `--literal-pathspecs`; paths follow `--`.
- Command-line config disables fsmonitor, hooks (`core.hooksPath=/dev/null`),
  untracked cache and credential helpers; sets `protocol.allow=never` and
  `core.attributesFile=/dev/null`.
- Diffs add `--no-ext-diff`, `--no-textconv`, `--no-color`, `--no-renames`,
  `--ignore-submodules=all`, fixed prefixes and `--no-relative`.
- A **complete replacement environment**, not the editor's inherited environment:
  `PATH=/usr/bin:/bin`, `HOME=/dev/null`, `XDG_CONFIG_HOME=/dev/null`, C locale and UTC;
  system/global Git config disabled via `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_SYSTEM`
  and `GIT_CONFIG_GLOBAL`; terminal prompts disabled, askpass/SSH executables set
  to `/bin/false`, protocols disallowed, lazy fetch and optional locks disabled.

**This is not an OS sandbox or a guarantee of no writes/network access.** Coral
requests no index mutations, hooks or network operations, and disables the named
helper/diff mechanisms. Repository-local configuration and attributes still matter:
clean filters or other repository-selected programs can execute with the user's
permissions, write files or access the network independently of Git's protocol
policy. `--no-ext-diff` and `--no-textconv` do not disable clean filters. Trust and
per-window disclosure are required precisely because “read-only Git” describes
Coral's requested operations, not all possible subprocess side effects.

## Not delivered; next safe slice

No staging/unstaging (file, hunk or selection), editable or multi-file diffs, commits,
branch/tag operations, worktree mutations, remotes/fetch/pull/push, blame/history,
stash operations, merge/rebase controls or conflict resolver are implemented. The
existing linked-worktree reads do not deliver those planned worktree operations.
There is no source-control dock/layout parity or external-change atomicity claim.

**Next: safe staging and index-snapshot validation**, before claiming mutation
support. Keep HEAD, index, disk and unsaved buffer states distinct; bind the reviewed
bytes to checked index/file identities, revalidate immediately before applying a
scoped operation, and refresh/refuse on races. Never fall back from a failed hunk
operation to staging the whole file, silently save an unsaved buffer, or stage bytes
different from the reviewed snapshot. Partial-stage preservation and external-index
race tests remain M4 acceptance work, not evidence supplied by this read-only slice.

## Final first-slice validation — passed

**The final `test-m4-slice` passed 105/105 steps, exit 0**, with **586/587 Zig tests
passed and 1 skipped**, in the [aggregate log](../../../.cache/coral-m4-readonly-gate.log).
This accepts the **first read-only slice and its regressions, not completed M4**.
The run includes the Unicode display-helper fix: shared escaping of Unicode
controls/bidi characters, bounded UTF-8-safe truncation and unchanged raw Git argv.
The final native report's `src/git/command.zig` hash matches the inspected helper.

| Final evidence | Result |
| --- | --- |
| Git pure root | **27 passed**: 21 parser/display + 5 command-policy/display + 1 import-root. The 22-test parser/root subtotal includes that root test. |
| Six language unit roots | **129 passed**: 16 protocol + 28 transport + 36 client + 27 features + 3 file-operation + 19 approval. |
| Main Zig root | **340 passed**. |
| Other Zig roots | **90 passed, 1 skipped** (trust root: 24 passed / 1 skipped; remaining roots: 23, 35 and 8 passed). |
| [Final native Git](../../../.cache/coral-git/results.json) | **15 passed / 0 failed / 0 blocked**, `complete_suite: true`; retained [run-dqo9pvi0](../../../.cache/coral-git/run-dqo9pvi0/results.json). |
| [Native language](../../../.cache/coral-language/results.json) | **89 passed / 0 failed / 3 optional blocked**, including pinned real ZLS passes. `clangd`, `typescript-language-server` and `pyright-langserver` are not installed; those smoke cases did not pass. |
| [Language/workspace lifecycle](../../../.cache/coral-workspace-lifecycle/results.json) | **20/20** native groups passed. |
| [Widgets](../../../.cache/coral-widgets/results.json) | **204/204 passed in 36.993 s**. |
| Fake-server fixture and full M1/M2 regressions | **25/25** fixture tests and the composed **full M1/M2 gates passed** in the aggregate. |
| [Hooks-disabled production](../../../.cache/coral-m4-readonly-production.log) | **46/46 steps, exit 0**, with fresh production executable compilation. |
| [Separate visuals](../../../.cache/coral-m4-readonly-visual.log) / [results](../../../.cache/coral-visual/results.json) | **40/40 steps, exit 0; 16/16 cases and four 2.0 font-ratio checks passed** on the aggregate's instrumented binary. |

The sole Zig skip is `trust_test`'s **“foreign owner store and trust directory
rejected when chown is available”** test: it returns `SkipZigTest` when
`geteuid() != 0`, as on this non-root host. It is **expected but not a pass**;
foreign-owner/chown coverage was not exercised by this run. The Zig root results
above explain the reported 586/587 summary. Widget, fixture and native counts are
separate harness results with overlapping coverage, **not an additive unique-test
total**. No aggregate wall time is claimed.

The visual matrix covers the **existing workbench**, not Source Control-window
visual parity. It uses headless Cairo, not a physical GPU/display or pixel-identical
cross-version golden comparison. The four ratios cover native/follow modes at
1024px and 390px. Follow Pearl cases exercise offline fallback/font compatibility;
live committed Pearl palette/font delivery remains unsupported by that harness.
No new input-to-paint or Git-window layout/accessibility qualification is implied.

### Earlier standalone evidence — retained separately

The earlier [standalone native results](../.cache/m4-git-native/results.json), retained
under [run-63gztd16](../.cache/m4-git-native/run-63gztd16/results.json), recorded
**15 passed / 0 failed / 0 blocked**, `complete_suite: true`, in **56.186 s**.
That is the earlier standalone run, **not the final aggregate's native report or
timing**. Both cover restricted/declined execution, diff sides/status kinds/conflicts,
unborn/detached HEAD, literal paths, root discovery/outside-root refusal, manual
refresh/unsaved exclusion, paging, and root/revoke/close teardown. The earlier
`zig test src/git_tests.zig` also passed **27 tests** during the initial docs update;
it is separate from, not additional to, the final aggregate's 27-test Git root.
Historical M3/M2 evidence elsewhere remains historical rather than being relabelled
as this final run.

From `subprojects/coral/`:

```sh
zig build git-unit -Doptimize=safe -j1
zig build git -Doptimize=safe -j1 -- --aqueous-prefix /usr
zig build test-m4-slice -Doptimize=safe -j1 --summary all
```

`git-unit` uses `src/git_tests.zig`; `git` uses the private native `tests/git.py`
harness and its instrumented binary. `/usr` is this host's installed test-tool
prefix; use a prepared fixture prefix on other hosts. The harness uses disposable
repositories/private Wayland, D-Bus and HOME/XDG state, not the user's repository;
fixture setup commits/stages only inside those disposable repositories. Its bounded
clean-filter cancellation cases deliberately exercise the disclosed helper boundary,
not a sandbox guarantee.

`test-m4-slice` composes **Git units + native Git + `test-m3`**, which includes the
M1/M2 regressions. It is the **first read-only slice's gate**, not completed M4
acceptance and not validation of staging, commits or the other future operations.

Implementation map: `src/git/status.zig` (bounded parser/labels),
`src/git/command.zig` (argv/environment/preview policy), `src/git/controller.zig`
(window, discovery, snapshots and lifetime), with App/workspace-policy and
menu/palette integration in their existing modules.
