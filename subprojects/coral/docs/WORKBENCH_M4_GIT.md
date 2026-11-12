# M4: Source Control inspection, checked index changes, core Git workflows and UI parity

**M4 core Git workflows and UI parity are implemented.** The third increment added
the **remaining core M4 workflows**: single-hunk stage/unstage with a strict
captured-snapshot applier, staged-only commit plus explicit stage-tracked-and-commit
and soft uncommit, branch create/switch/delete and lightweight tags, worktree
list/add/remove/open, named stash, conflict resolution and
merge/rebase/cherry-pick/revert continue/abort, remotes fetch/pull/push/force-with-lease,
and history/blame/commit diff/host permalinks. These join explicit discovery, status,
bounded noneditable diff previews and selected full-file staging/unstaging in a
**separate native Source Control window**. The **UI-parity increment** adds a real
**Source Control dock panel** (grouped Staged/Unstaged/Untracked, tree/flat, commit
entry, reviewed section/all/selected staging) and an editable multi-file **Project
Diff window** (unified/split/word modes, gutter markers, hunk navigation,
original/current/both sides, hunk and change-line-selection staging through the
strict sub-hunk backend). The UI increment passed **targeted validation**
([evidence](#m4-ui-parity-increment-validation--targeted)); the full aggregate was
**not rerun** for it per user request, so the earlier parent aggregate,
hooks-disabled production and separate visual qualification remain **historical
core-workflow evidence** ([final gate](#final-m4-core-workflow-validation--accepted)).
This is **not full Zed parity**: remaining limits include no annotated tags/PR API,
hunk absent-side/mode refusals, change-line-index selections, explicit panel refresh
without watchers, a read-only original diff side, and no rerun visual matrix for the
new UI. Supported-case expansion remains relevant because these increments
deliberately refuse many repository configurations.
See [current status](WORKBENCH_STATUS.md) and the [full M4 plan](WORKBENCH_IMPLEMENTATION_PLAN.md#8-zed-style-git-integration).

## Open Source Control

Use the **Git** menu or command palette (`Ctrl+Shift+P`):

| Command | Current behavior |
| --- | --- |
| **Git: Source Control…** | Review the subprocess disclosure, then open the window and discover repositories/read status; present the existing window without automatic refresh if already open. |
| **Git: Refresh repositories** | Explicitly rediscover roots and reload status; if not already approved/open, go through disclosure first. |
| **Git: Unstaged diff** | For the selected changed file, compare **index → disk**, not the editor buffer. |
| **Git: Staged diff** | For the selected changed file, compare **HEAD → index** (`git diff --cached`). |
| **Git: Stage selected file…** | Prepare a separate review replacing one selected index path with its complete captured **disk** contents/mode, or removing it when absent. |
| **Git: Unstage selected file…** | Prepare a separate review restoring one selected index path from **HEAD**, or removing it when absent from HEAD (including unborn HEAD). |
| **Git: Stage selected hunk… / Unstage selected hunk…** | Prepare a separate **ONE HUNK, NOT THE WHOLE FILE** review applying one selected hunk to the captured index snapshot; all other hunks and paths are preserved. |
| **Git: Next hunk / Previous hunk** | Move the selected hunk within the current diff preview. |
| **Toggle Source Control dock** (`toggle-source-control`) | Hide the Source Control dock panel when visible; otherwise show/focus it and refresh its status through the dock disclosure. |
| **Focus Source Control** (`focus-source-control`) | Show/focus the dock panel and refresh its status. |
| **Git: Project Diff…** | Open the multi-file Project Diff window for the discovered repository; inherits Source Control trust/disclosure. |
| **Git: Refresh Project Diff** | Explicitly recapture the multi-file diff; unsaved buffers stay excluded. |
| **Git: Project Diff next hunk / previous hunk** | Move the selected hunk within the current file's diff. |
| **Git: Project Diff stage hunk… / unstage hunk…** | Prepare a separate captured before/after review applying one hunk through the strict index backend. |
| **Git: Project Diff stage selection… / unstage selection…** | Prepare the same review for the selected change-line ranges (strict sub-hunk). |
| **Git: Project Diff unified view / split view / word view** | Switch the render mode. |
| **Git: Commit staged…** | Review the exact staged set and commit it with a typed message (`git commit -F -`); unstaged/untracked changes are preserved. |
| **Git: Stage tracked and commit…** | Explicit `git add -u` staging review (never untracked files), then a separate commit review of the resulting staged set. |
| **Git: Uncommit last…** | Soft-reset review via compare-and-swap `update-ref HEAD <parent> <expected>` keeping index and worktree; initial, merge, published HEAD and in-progress operations are refused. |
| **Git: Branches… / Create branch… / Switch branch… / Delete branch…** | Branch listing and reviewed create/switch/delete; merged safe delete, typed-name force delete, dirty-worktree protection. |
| **Git: Tags… / Create lightweight tag…** | Read-only tag listing; lightweight tag creation at HEAD. |
| **Git: Worktrees… / Add worktree… / Remove worktree…** | Worktree listing, reviewed add and clean-only remove; the list's Open action hands off the path. |
| **Git: Stash push… / Stash list… / Stash apply… / Stash pop… / Stash drop…** | Named tracked/staged/all stash push, entry listing/diff and reviewed apply/pop/drop. |
| **Git: Conflicts… / Resolve conflict using current… / incoming… / both…** | Unmerged-path listing, base/ours/theirs stage previews and reviewed worktree write + stage. |
| **Git: Manual conflict resolution** | Refused with guidance to edit/save in the editor and stage. |
| **Git: Continue merge/rebase… / Abort merge/rebase…** | Explicit continue/abort of the operation detected from gitdir state. |
| **Git: Remotes… / Fetch… / Pull… / Push… / Force push with lease…** | Remote listing and network operations after a separate credential-helper disclosure; pull ff-only by default. |
| **Git: File history… / Blame… / Commit diff… / Open permalink…** | Bounded read-only history/blame/commit diff and user-opened GitHub/GitLab/Codeberg https permalinks. |

First approve the workspace through **Workspace: Settings and Trust…**, then accept
**Continue with read-only Git** in the separate disclosure. Both are required.
That disclosure authorizes inspection, **not writes**. Invoking a mutation before
approval only opens disclosure; it does not queue a write or approve a later review.
Select an actual changed-path row in Source Control and invoke the command again.
The active editor document is not the mutation target; there is no whole-repository
fallback.
There is **no Git execution at startup or in restricted mode**, and declining the
disclosure launches nothing. Approval is window-local and not persisted; closing
Source Control or invalidating its workspace/trust clears it. A peer editor window
must obtain its own approval. Root/trust changes and window shutdown cancel work;
workspace/request generations reject stale callbacks and owned processes are reaped.
Workflow writes additionally consume a **separate per-operation native confirmation
or review**; fetch/pull/push require a further **credential-helper disclosure**. See
[Core Git workflows](#core-git-workflows).

The window has a repository/root picker, branch/HEAD/upstream/ahead/behind summary,
a paged changed-path list, Refresh, Staged Diff / Unstaged Diff, Stage file… /
Unstage file… and Stage hunk… / Unstage hunk… buttons with Next hunk / Previous hunk
navigation and a selected-hunk label. Each row shows **index status then worktree
status**, rather than separate staged and unstaged trees. Workflow commands open
their own native dialogs (pickers, name inputs, reviews and confirmations). The
window's preview remains a read-only text view; the **Source Control dock panel**
and **Project Diff window** below provide the grouped/commit-entry and editable
multi-file surfaces. There are no default Git keyboard shortcuts.

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
  and reads. Git metadata can live outside the owning root. Worktree
  list/add/remove/open is delivered separately (see [Worktrees](#worktrees));
  discovery itself performs no worktree writes, and none of this is worktree
  isolation or a sandbox around metadata reads.
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
Unmerged/conflict entries get an explicit unsupported-preview message in the diff
view, not a combined diff; resolution is a separate reviewed workflow (see
[Conflicts and in-progress operations](#conflicts-and-in-progress-operations)).
Binary and non-UTF-8 diffs get non-text notices.
Oversized captures/previews are refused rather than displayed as complete partial
results. A selected side with no change in the status snapshot asks for Refresh
if disk/index state has since changed.

**Inspection refresh is manual** apart from the explicit post-apply invalidation/
refresh described below. There are no worktree/index/HEAD/config watchers or periodic
Git polling; the dock panel and Project Diff window also refresh explicitly. Selecting a repository reads its status; requesting a diff reads that
side at that time. Status and subsequent diffs are **not an atomic snapshot with
external disk/index/HEAD changes**. A frozen, noneditable preview is not proof that
an external Git process has left the index unchanged.

The window shows an unsaved-document count across editor windows; it updates on
interaction, not continuously, and the review labels its count as captured at
review creation. **Dirty buffers are allowed, excluded and never saved.** No command
here stages editor text and no buffer-to-index operation exists. Saving is optional:
only save explicitly if you want disk state to reflect your edits, then Refresh.
Pending loads/saves/reloads and manager-wide operation admission can still block a
mutation; allowing dirty buffers is not permission to race an in-flight save.

## Selected full-file review and publication

1. **Prepare on a worker, with no repository writes.** Capture the full index and
   selected disk file, HEAD and resolved branch ref/packed refs, root/Git/common-dir
   identities and `.git`/`commondir` binding witnesses. Private scratch-index writes
   live outside the repository. HEAD, index, disk and unsaved buffers stay distinct.
2. **Approve a separate complete review.** Scrollable, noneditable before/after
   panes show the entire captured bytes with escaped controls/backslashes and LF
   markers, existence, modes, byte counts and SHA-256 digests of the original bytes.
   Empty and absent are distinct. This explicitly says **FULL FILE, NOT HUNKS**;
   staging replaces any partial staging of this selected path with the reviewed
   disk version, while unstaging restores HEAD. Other paths are not selected.
   Cancel is the default. Over-budget review is refused, never truncated approval.
3. **Revalidate before apply.** Current trust/permit, workspace/request generations,
   root and actual repository/row/page selection must still match. A manager-wide
   file-operation barrier is acquired for the index before dispatching worker apply
   and held through worker cleanup/delivery. Root/trust/selection/close invalidation
   cancels work; stale preparation cannot become approval.
4. **Publish only the checked single-path proposal.** Acquire `index.lock` with
   exclusive creation; never delete a foreign/replaced lock. Recheck snapshots and
   conversion policy under the lock. Stage hashes captured bytes with `--no-filters`;
   unstage uses the captured HEAD entry. Update a private index and verify that all
   unrelated logical entries (paths, modes and object IDs) remain unchanged. Clear
   filesystem stat caches both before using the private copy and before publication,
   preventing racy-clean entries from hiding unrelated worktree changes. Subsequent
   Git refreshes may therefore perform extra disk reads.
5. **Durability before publication.** For a non-deletion, fsync the selected local
   loose blob, its prefix directory and the objects directory. Write/fsync the index
   lock, recheck full snapshots, bindings and lock ownership, then atomically rename
   it over the index and fsync the Git directory. An unrelated external index change
   invalidates the whole review rather than being overwritten or merged implicitly.

Every apply attempt **consumes its review**, even on failure: retry requires new
preparation and approval. Attempted applies invalidate status/diff and refresh when
the controller remains valid. Cancellation after index publication is **success**,
not rollback; a post-publication directory-fsync failure reports **committed, durability
uncertain** and must not be blindly retried. Here “committed” means index publication,
**not a Git commit**. An aborted pre-publication apply can leave an unreachable blob;
it does not publish the index or change worktree files. Cleanup may leave an owned
lock if its identity cannot be verified rather than risk deleting a foreign lock.

This protects against **cooperative Git writers**, not malicious same-UID processes,
mount aliases or adversarial ref changes in the final recheck-to-rename window.
HEAD/refs are checked, not locked into a cross-ref/index transaction. Linux `/proc`
and descriptor-based bindings are required; this is not a claim of support for all
repositories.

## Single-hunk review and publication

The diff preview parses the selected file's captured unified diff into bounded
hunks (`src/git/hunk.zig`). **Next hunk / Previous hunk** move the selection;
**Stage selected hunk… / Unstage selected hunk…** prepare a separate review
labelled **ONE HUNK, NOT THE WHOLE FILE**, showing the complete captured
before/after index bytes plus the regenerated hunk patch, existence, modes, byte
counts and SHA-256 digests, under the same escaped-display bounds as full-file
review. Cancel is the default; over-budget review is refused.

The applier is **strict and snapshot-bound**: a hunk applies only at its exact
recorded line position and only when every matched line is byte-identical in the
captured snapshot. There is **no fuzz and no offset search**. Exact bytes are
preserved, including CRLF (CR stays inside line content) and a missing final
newline. A hunk is identified by its zero-based ordinal plus the SHA-256 of its
canonical header/body form — never by file-header paths or the decorative section
heading — so the displayed hunk and the regenerated hunk must match. The patch is
regenerated from the captured before/target bytes in private temp copies, never
from a live displayed diff. Publication uses the same checked single-path index
transaction as full-file staging: all other hunks of the file and all unrelated
paths are preserved, with the same lock, snapshot, binding and durability rechecks.
Every attempt consumes its review.

Hunk-specific refusals:

- **Absent sides** (`AbsentSide`): both the current and target sides must exist; a
  hunk never creates or deletes the path. Use full-file stage/unstage for
  additions and deletions.
- **Mode changes** (`ModeChangeUnsupported`): the target side's mode must equal the
  captured index side's mode; use the full-file review for mode changes.
- All conversion, index-feature, conflict, size and packed-only-blob refusals below
  apply unchanged.

Change-line-selection staging/unstaging is delivered through the Project Diff
window's strict sub-hunk backend; selections share every refusal above. See
[Project Diff window (UI parity)](#project-diff-window-ui-parity).

## Mutation support and refusals

- Selected regular UTF-8 text only: modes `100644`/`100755`, including additions,
  modifications, deletions and mode changes; absent index/unborn and detached HEAD,
  SHA-1/SHA-256 and checked `.git` file/linked-worktree bindings are handled within
  the other restrictions. `core.filemode=false` preserves an existing index mode
  (new files use `100644`). No checkout or worktree-management operation occurs.
- **256 KiB per file/blob** in the backend. Disk is captured and checked even for
  unstage; binary (NUL), non-UTF-8, symlinks/nonregular files and oversized selected
  disk/index/required HEAD contents are refused. Paths are bounded to 4,095 bytes
  and 64 components, with unsafe components and `.git` components refused.
- Review additionally requires **256 KiB escaped display per side, 4,000 lines,
  2,048 source bytes per line**. Backend acceptance alone does not authorize an
  incomplete UI review.
- Staging refuses conversion attributes `filter`, `text`, `eol`,
  `working-tree-encoding`, `ident` and `crlf` when explicitly present, **including
  `-text` and `-filter`**. `core.autocrlf` must be absent or false; true and `input`
  fail closed. Mutation policy retains configured `core.attributesFile` for this
  check rather than silently suppressing it. These staging conversion checks are
  not an unstage conversion pipeline: unstage restores raw HEAD bytes.
- Full index bound: **16 MiB**. Only v2/v3 without unsupported flags/features:
  sparse/split indexes, v4, assume-unchanged, extended flags (including skip-worktree
  and intent-to-add), sparse-directory entries and unknown mandatory extensions
  are refused. Conflicts **anywhere in the index** refuse the transaction. Selected
  symlink/submodule/tree entries are unsupported. Non-files ref storage, symbolic
  HEAD outside `refs/heads/`, and chained symbolic branch refs are refused.
- Every non-deletion requires a syncable **local loose target blob**. If the blob
  to be referenced by the new index is available only in packs or alternates,
  apply refuses with **`ObjectDurabilityUnavailable`**, including when `hash-object`
  reuses a packed object or unstage restores a packed-only HEAD blob. It does not
  unpack/copy objects as a fallback. Other packed objects do not by themselves
  imply refusal. Object fsync failures also prevent publication.
- Stale bytes/metadata/existence/bindings, an existing or replaced index lock,
  pending editor operations and invalid trust/generations cause refusal or
  cancellation, not an unchecked fallback. A fresh review is required after repair.
- Hunk operations share every refusal above and additionally refuse absent sides
  and mode changes; see [Single-hunk review and publication](#single-hunk-review-and-publication).

## Core Git workflows

Every workflow below requires the trusted workspace, the per-window Source Control
disclosure and a selected repository. Read-only preparation uses the locked-down
inspection policy; **repository writes use a separate write policy**
(`src/git/env.zig`): the user's Git configuration and identity apply, and configured
hooks/signing can execute programs with the user's permissions. **This is not a
sandbox.** Each write consumes its own explicit native confirmation or review; the
read-only disclosure never authorizes a write. Writes hold the manager
file-operation barrier (commit, refs, worktree, stash, conflict and remote writes
alike), run in supervised workers with cancellation/reaping, and are invalidated by
root/trust/selection/close changes. Unsaved buffers are never saved; stash
push/apply/pop and conflict continue/abort additionally refuse while unsaved buffers
exist under the repository. Branch switch/delete guard open documents (`guardTree`),
and stash/conflict worktree-affecting writes refuse while any editor document is
open under the repository (`openDocumentUnderRepo`), so an open buffer is never
clobbered or left saving back to a rewritten pathname.

### Commit, stage-tracked-and-commit and uncommit

- **Git: Commit staged…** reviews the exact staged set (name-status list, stat
  summary, staged/unstaged counts, branch/HEAD/upstream) and commits **only the
  staged index** with a typed message via `git commit -F -` (message on stdin; no
  shell, no `-a`, no `--allow-empty`). Unstaged and untracked changes are preserved.
  An empty staged set is refused before any write. Hooks (pre-commit,
  prepare-commit-msg, commit-msg, post-commit) and GPG/SSH signing are disclosed
  and may execute configured programs.
- **Git: Stage tracked and commit…** is the explicit Zed-style convenience: a
  separate review of `git add -u` (all tracked modifications/deletions, **never
  untracked files**), then a fresh commit review of the resulting staged set.
  **Unmerged conflicts are refused before any `add -u`**: the worker rechecks HEAD
  and the full status (`recheckStage`) before apply, so a conflict is never silently
  staged or resolved. The default remains **Commit staged only**.
- **Git: Uncommit last…** is a soft reset: HEAD moves back one commit and **index
  and worktree are kept exactly as they are**. It is not a rollback of file contents
  and never hard-resets. The write is a compare-and-swap
  `update-ref HEAD <parent> <expected>` that only succeeds while HEAD still equals
  the reviewed value, so a concurrent HEAD move fails closed instead of re-resolving
  `HEAD~1` to a different commit; the reviewed parent is pinned. **Initial commits
  (no parent), merge commits (two or more parents), published HEAD and in-progress
  merge/rebase/cherry-pick/revert operations are refused**; publication is checked
  with `merge-base --is-ancestor HEAD upstream` against the configured upstream, and
  the review states when no upstream is configured. HEAD, its single parent and the
  operation state are rechecked immediately before the write.

### Branches and lightweight tags

- **Branches…** lists local and remote-tracking branches with upstream/track state.
  **Create branch…** validates the name (check-ref-format rules plus UTF-8/argv
  safety) and creates at current HEAD. **Switch branch…** uses `git switch` with
  **no `--force` or `--discard-changes` ever**. Remote-tracking branches cannot be
  switched to or deleted directly.
- **Delete branch…** verifies the branch is merged into current HEAD
  (`merge-base --is-ancestor`) and uses safe `git branch -d`. An unmerged branch
  requires a **separate force confirmation** (`git branch -D`) in which you must
  **type the exact branch name**; anything else cancels.
- A dirty worktree (fresh status) **blocks switch/delete** with an explicit choice:
  cancel, or stash first using the separate Stash commands. The dialog itself never
  stashes, discards or forces.
- **Tags…** lists tags read-only, labelled lightweight/annotated. **Create
  lightweight tag…** creates a lightweight tag at HEAD. **Annotated tags, tag
  signing and tag deletion are not delivered.**

### Worktrees

- **Worktrees…** lists main/linked worktrees with branch, detached, locked and
  prunable state. **Add worktree…** validates the requested path lexically inside
  the owning workspace root, refuses registered worktree paths and metadata
  locations, and enforces Git's one-worktree-per-branch restriction before writing.
  Git refuses existing non-empty paths (no overwrite); an existing empty directory
  may be used without data loss.
- **Remove worktree…** is **clean-only**: a fresh status capture must show zero
  changes; locked, prunable and main worktrees are refused; `--force` is never used.
- The list's **Open selected worktree** action hands the path to a parent callback
  when one is installed; **without a callback it messages the path** for use with
  Open Workspace…. Non-Git roots are never touched. This is worktree management,
  not agent isolation.

### Stash

- **Stash push…** takes a name and a scope: **tracked** (staged + unstaged tracked
  changes), **staged** (staged only, requires **Git ≥ 2.35**, version-gated) or
  **all** (tracked + untracked; **ignored files are never stashed**). Push refuses
  while unsaved buffers exist under the repository, and push/apply/pop refuse while
  an editor document is open under the repository (`openDocumentUnderRepo`).
- **Stash list…** lists named entries and shows a selected entry's diff.
  **Stash apply…** applies and **preserves the entry**. **Stash pop…** applies
  first and drops only after a successful apply **and a separate explicit
  confirmation**; a **failed apply always preserves the entry**. **Stash drop…**
  is loss-producing and confirmed.

### Conflicts and in-progress operations

- **Conflicts…** lists unmerged paths from `ls-files -u` with per-path stages and
  conflict kind, and previews the **base/ours/theirs** stage bytes. Absent stages
  are labelled (e.g. no base for both-added conflicts, or a deleted side).
- **Resolve conflict using current… / incoming… / both…** writes the reviewed stage
  bytes (both = the two sides joined with a single separating LF when needed) to
  the worktree file via a descriptor-checked atomic replace in a worker, then
  stages it with `git add`. The file must not be open in an editor; unsaved buffers
  are never saved. **Publication wins over cancellation**: once the atomic replace
  renames, the worktree change is recorded and reported even if a close raced in;
  a write cancelled before publication warns that the worktree file is unchanged
  and refreshes Source Control so the new disk state is not mistaken for the old
  snapshot.
- **Manual conflict resolution is refused** with guidance to edit/save in the
  editor and stage. **Binary, rename/delete and oversized conflicts are refused as
  non-text**; there is no combined diff or marker guessing.
- Merge/rebase/cherry-pick/revert state is read from **gitdir state files**, never
  guessed from conflict markers. **Continue merge/rebase… / Abort merge/rebase…**
  run the detected operation's `--continue`/`--abort` after explicit confirmation
  and are refused while unsaved buffers exist under the repository.

### Remotes and network disclosure

- **Remotes…** lists fetch/push URLs (separate pushurl honoured). **Fetch…**,
  **Pull…** and **Push…** require a **separate credential-helper disclosure** in
  addition to Source Control approval: unlike inspection they use the user's Git
  identity and configured credential/askpass helpers, which may execute programs
  and access secrets (tokens, SSH keys), and they contact the configured remote
  and transfer repository data.
- **Pull** defaults to **ff-only** (refuses non-fast-forward updates); **merge**
  and **rebase** modes must be chosen explicitly. Push is **never backgrounded**.
- **Push** targets the fully-qualified **current local branch** refspec
  `refs/heads/<branch>` — never the upstream's branch name, so a differently named
  remote branch is not pushed by accident. The credential-helper disclosure names
  the exact remote and refspec (and current local branch); the approved action
  launches exactly that disclosed target. **Detached and unborn HEAD are refused**
  (check out a local branch / create a commit first), as are invalid branch names.
- **Force push with lease…** is a distinct confirmation: `--force-with-lease`
  updates the remote ref only if it still matches the value the repository last
  fetched; Git refuses if someone else pushed since. It can still discard remote
  commits the local repository has not fetched.
- Network commands use a **120-second timeout** and **64 KiB output budget**;
  inspection keeps the 15-second policy. There is no background fetch/push.

### History, blame and permalinks

- **File history…** shows a bounded log (at most **500 entries**) for a
  repository-relative path derived from the active document; **Commit diff…**
  shows a selected commit's diff; **Blame…** parses blame porcelain with a
  **5,000-line budget**. All are read-only inspection under the locked-down policy;
  no network or repository writes occur.
- **Open permalink…** constructs a **GitHub/GitLab/Codeberg** https blob permalink
  from the validated web remote (https/ssh/scp forms, subgroups, `.git` suffix),
  with strict https validation: unsafe schemes, userinfo, controls and traversal
  are refused. The URL opens in the user's default browser **only after a separate
  external-link confirmation**. Local/non-host remotes are refused. **There is no
  PR/issue API client.**

## Source Control dock panel (UI parity)

`src/git/panel.zig` renders a real **third dock panel** beside Explorer/Search
(`src/workbench/layout.zig` `Panel.source_control`). The activity rail has a Source
Control button and same-dock tabs include it; the panel is movable/resizable/hideable
through the existing dock system, and compact windows keep the single-auxiliary-panel
behavior. `layout.State` persists `source_control` (dock side, default left) and
`source_control_visible` (default false) through the session layout; partial layouts
decode with defaults and invalid values are refused.

- **Grouped status:** Staged / Unstaged / Untracked sections with a branch/HEAD
  summary and per-section counts; a **tree/flat** toggle (rendering only, never
  section order); 128 file rows per page plus at most 128 tree directory rows and 3
  section headers. Conflicts stay visible, but every write is refused while any
  unmerged entry exists.
- **Commit entry:** a commit-message entry and **Commit staged…** button delegate to
  the reviewed commit workflow (`app.git_commit.showCommit`) unless the parent wires
  `on_commit`; the dock itself never commits.
- **Reviewed staging:** Stage all (per section) / Unstage all / Stage selected /
  Unstage selected each open a separate native review of the **exact literal Git argv
  and path set**, then hold the shared manager barrier on the repository index path
  and run a GTask worker under the write environment. The worker rechecks HEAD
  **compare-and-swap** against the reviewed snapshot, refuses in-progress
  merge/rebase/cherry-pick/revert and unmerged conflicts, and compares a fresh status
  capture's target path set **byte-for-byte** with the reviewed set before applying.
  Section staging uses `git add -u --` (tracked unstaged), `git add -- <paths>`
  (untracked, explicit paths) and `git reset --` (staged, whole index whose reviewed
  staged set is rechecked exactly); selected writes name one path.
- **Bounds:** 1 MiB status capture / 10,000 entries; 1,024 explicit paths / 128 KiB
  argv per write; 256 KiB review text; 15-second process timeouts.
- **Limits:** the dock reuses the Source Control window's repository discovery (open
  **Git: Source Control…** and Refresh there first); it has its own per-window dock
  disclosure (“Continue with read-only Git”) on top of workspace trust. **Explicit
  refresh only — no watchers, no startup work, no automatic refresh.** Dirty buffers
  are excluded and never saved; no worktree write, checkout, commit or network access
  from the dock. Submodule contents are never inspected; gitlink changes stage like
  other tracked changes. Repository-local clean filters can still execute: **not a
  sandbox**.

## Project Diff window (UI parity)

`src/git/project_diff.zig` with the pure parser/renderer `src/git/diff_render.zig`
opens a **multi-file** diff window (up to **4,096 files**, **1 MiB** diff capture,
15-second inspection timeout). It inherits discovery and trust/disclosure from the
parent Source Control controller (`app.git`); it never runs Git on its own authority
and never bypasses the disclosure.

- **Modes and sides:** **unified/split/word** render modes with gutter markers and
  old/new line numbers; word mode highlights intra-line changed ranges. **Original /
  current / both** side selection and an **Unstaged diff (index → disk) / Staged diff
  (HEAD → index)** picker. Hunk navigation (next/previous) with a selected-hunk label.
  Binary/mode/rename/absent sides are classified per file with explicit non-text
  states; oversized renders are refused, never partially shown.
- **Editable current side:** the current side binds an **ExcerptEditor to the real
  open Document** through the shared editor history (`app.history`), exactly like
  `app.openExcerpt`. The **original side is always a read-only GtkSourceView**; the
  current side falls back to read-only when the file is not open, the hunk region is
  absent from the buffer, or the excerpt/editor is unavailable.
- **Hunk and selection staging:** stage/unstage **hunk** or **change-line selection**
  reuse the strict `index_transaction` backend (prepare/apply) through one-shot GTask
  workers and a **separate native before/after review** with SHA-256 digests. A
  selection is a set of half-open **change-line index ranges within one hunk** — the
  `-` and `+` body lines in body order; context lines are not counted. Ranges must be
  non-empty, sorted and non-overlapping; selecting every change-line reproduces the
  whole hunk. The parent hunk's `HunkRef` digest still identifies the target, so a
  changed diff invalidates the selection. Staging requires the unstaged diff
  displayed; unstaging requires the staged diff displayed, so the captured digest
  matches the backend's regenerated diff. All other hunks/paths are preserved; every
  full-file/hunk refusal applies, including absent sides and mode changes.
- **Unsaved edits:** staging always uses the captured disk/index snapshot. The window
  warns that **unsaved edits are excluded and never saved**, and offers **Save current
  file** through a parent-set callback; there is no buffer-to-index staging.
- **Limits:** no worktree file write, no commit, no watchers, no startup work, no
  network. Only the current side is editable; the original side is read-only.

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
| Source Control dock rows | 128 file rows per page, plus at most 128 tree directory rows and 3 section headers |
| Source Control dock write | 1,024 explicit paths / 128 KiB argv per write; 256 KiB review text |
| Project Diff files / capture | 4,096 files; 1 MiB diff capture; 15-second inspection timeout |
| Project Diff render | Oversized renders/word ranges refused (`RenderTooLarge`); no partial render |
| Mutation file/blob / full index | 256 KiB / 16 MiB |
| Mutation review, per side | 256 KiB escaped display, 4,000 lines, 2,048 source bytes per line; no partial approval |
| Commit message / commit review | 64 KiB message; 256 KiB review body |
| Branch picker / stash and conflict lists | 512 picker rows; 256 visible stash/conflict rows |
| Worktree listing | 1,024 worktrees |
| History log / blame | 500 entries / 5,000 lines; 1 MiB capture; 64 KiB output budget |
| Remote operations | 64 KiB output budget; 120-second network timeout (inspection stays 15 seconds) |
| Git job | One active job per controller; 15-second timeout per inspection command, not a whole-refresh deadline |

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

**This is not an OS sandbox or a guarantee of no writes/network access.** Inspection
requests no index mutations; separately approved selected-file apply does. Neither
requests hooks or network operations. Coral disables the named
helper/diff mechanisms. Repository-local configuration and attributes still matter:
clean filters or other repository-selected programs can execute with the user's
permissions, write files or access the network independently of Git's protocol
policy. `--no-ext-diff` and `--no-textconv` do not disable clean filters. Trust and
per-window disclosure are required precisely because “read-only Git” describes
Coral's requested operations, not all possible subprocess side effects.

## UI parity delivered; remaining scope and limits

The **Source Control dock panel** and **Project Diff window** above deliver the
planned UI-parity surfaces: grouped staged/unstaged/untracked status with tree/flat
modes and a commit entry, reviewed file/section/all staging, and editable multi-file
review with unified/split/word modes, gutter markers, hunk navigation and
hunk/change-line-selection staging. **This is still not full Zed parity.** Remaining
scope and limits:

- **No annotated tags**, tag signing/deletion, or PR/issue API client; permalinks
  are validated https blob URLs opened by the user.
- **Hunk/selection limits:** absent sides and mode changes are refused; there is no
  fallback from hunks to whole-file staging. Selections are **change-line indices
  within one hunk**, not arbitrary editor-buffer selections or cross-hunk ranges.
- **No watchers:** the dock panel and Project Diff refresh explicitly; there is no
  worktree/index/HEAD/config watching and no buffer-to-index staging (unsaved edits
  are excluded; save first).
- **Project Diff editing is current-side only:** the original side is always
  read-only, and the current side is read-only when the file is not open in the
  editor.
- **Conflict limits:** binary, rename/delete and manual resolution are refused;
  there is no ancestor-context editor or interactive marker navigation.
- **Worktree open** hands off to a parent callback when installed and otherwise
  messages the path; there is no automatic workspace opening or agent isolation.
- Packed-only target blobs still refuse with `ObjectDurabilityUnavailable`; there
  is no general external-change atomicity claim.
- **Validation boundary:** the UI increment passed targeted validation only; the
  full aggregate was not rerun per user request, the prior core-workflow final gate
  remains historical, and the **visual matrix was not rerun for the new UI**.

**Next:** supported-case expansion and the remaining repository-model targets
(watch-based refresh, buffer-to-index staging) as planned. Hunk/selection operations
preserve partial staging and refuse races; they never fall back to whole-file staging
or silently save buffers.

## M4 UI-parity increment validation — targeted

**Targeted validation passed for the UI-parity increment; the full aggregate was not
rerun per user request.** The prior core-workflow final gate below remains historical
evidence for the core workflows, not for this increment.

| Evidence | Result |
| --- | --- |
| `session-unit` | **25/25 passed** ([units log](../../../.cache/coral-m4-ui-units.log)); includes the persisted `source_control` layout roundtrip, partial-decode and invalid-value refusal tests. |
| Widgets | **209/209 passed in 53.711 s** ([units log](../../../.cache/coral-m4-ui-units.log), [results](../../../.cache/coral-widgets/results.json)). |
| Native docks | **27/27 cases passed** ([docks log](../../../.cache/coral-m4-ui-docks.log), [results](../../../.cache/coral-docks/results.json)). |
| `git-index-unit` | **59 passed**: 21 index-transaction (incl. selection publication) + 26 hunk (incl. sub-hunk/selection) + 6 diff_render + 5 command-policy + 1 import-root. |
| Focused hunk workflows | **2 cases passed**: `hunk-stage-preserves-other` and `hunk-stage-second-navigation`. |
| Integrated build | **46/46 steps passed**. |

Counts overlap across harnesses and are not an additive unique-test total. The
**visual matrix was not rerun for the new UI**; no Source Control-dock or Project
Diff visual parity is claimed. The full `test-m4-slice` aggregate, hooks-disabled
production and visual qualification were **not rerun** for this increment; their
last accepted results remain the historical core-workflow gate below.

## Final M4 core-workflow validation — accepted

**Historical core-workflow gate: this evidence predates the UI-parity increment and
was not rerun for it.** The parent aggregate, hooks-disabled production and separate
visual qualification passed for the implemented core Git workflows. This accepts the
third (workflow) increment together with inspection and selected full-file/hunk
staging and their M1/M2/M3 regressions — **not full Zed/UI parity**. The UI-parity
increment's targeted evidence is recorded separately above. The earlier standalone
workflow-increment counts (commit 17 + refs 29 + stash 16 + remote 19 = 81, retained
`.cache/m4-index-native` run-drp8t2oj / `.cache/m4-workflows-native` run-vj5ss182)
are **superseded** by the final aggregate below; the first-slice and second-increment
gates remain historical.

Final aggregate: `zig build test-m4-slice -Doptimize=safe -j1 --summary all`
completed **117/117 steps, exit 0**, with **475/475 Zig tests passed and no skips
reported**, in the [final gate log](../../../.cache/coral-m4-final-gate.log). The
475 fresh passes are the four workflow unit roots (**94**) plus the main Zig root
(**381**); `git-unit`, `git-index-unit`, the six language unit roots and the
trust/session/project/appearance runners were cached from prior passes. The trust
root's expected non-root foreign-owner skip remains in that cached runner (not
re-executed here); it is **not a pass**.

| Evidence | Result |
| --- | --- |
| `git-unit` (`src/git_tests.zig`) | **27 passed**: 21 parser/display + 5 command-policy/display + 1 import-root (cached in the final aggregate). |
| `git-index-unit` (`src/git_index_tests.zig`) | **40 passed**: 20 index-transaction + 14 hunk + 5 command-policy + 1 import-root (cached in the final aggregate). |
| `git-workflow-unit` commit root (`src/git_commit_tests.zig`) | **25 passed**: 10 commit fixtures + 4 commit policy + 5 conflict policy + 5 command-policy + 1 import-root. |
| `git-workflow-unit` refs root (`src/git/refs_test.zig`) | **30 passed**: 10 refs/worktree fixtures + 9 refs + 5 worktree + 5 command-policy + 1 import-root. |
| `git-workflow-unit` stash root (`src/git/stash_test.zig`) | **18 passed**: 7 stash/conflict fixtures + 5 stash + 5 conflict + 1 import-root. |
| `git-workflow-unit` remote root (`src/git/remote_test.zig`) | **21 passed**: 7 remote/history cross-checks + 6 remote + 7 history + 1 import-root. |
| `git-workflow-unit` total | **94 passed across the four roots (25 + 30 + 18 + 21)**, rerun fresh in the final aggregate. |
| [Native Git](../../../.cache/coral-git/results.json) (`git`, [run-c5jysbxk](../../../.cache/coral-git/run-c5jysbxk/results.json)) | **46 passed / 0 failed / 0 blocked**, `complete_suite: true`, 311.338 s: 15 inspection + 31 full-file mutation cases. |
| [Native workflows](../../../.cache/coral-git-workflows/results.json) (`git-workflows`, [run-5haen4b7](../../../.cache/coral-git-workflows/run-5haen4b7/results.json)) | **36 passed / 0 failed / 0 blocked**, `complete_suite: true`, 176.254 s. |
| [Native language](../../../.cache/coral-language/results.json) | **89 passed / 0 failed / 3 optional blocked** (clangd, TypeScript and pyright not installed), including pinned real ZLS passes. |
| [Language/workspace lifecycle](../../../.cache/coral-workspace-lifecycle/results.json) | **20/20** native groups passed. |
| [Widgets](../../../.cache/coral-widgets/results.json) | **204/204 passed in 47.928 s**. |
| Fake-server fixture and full M1/M2 regressions | **25/25** fixture tests; the composed **full M1/M2 gates passed** (271 native groups: 40 workflows, 14 integration, 13 recovery, 18 workspace, 19 explorer, 9 search, 17 policy, 19 sessions, 27 docks, 27 windows, 25 operations, 25 projects, 18 roots). |
| [Hooks-disabled production](../../../.cache/coral-m4-final-production.log) | **46/46 steps, exit 0**, with fresh production executable compilation in 37 s. |
| [Separate visuals](../../../.cache/coral-m4-final-visual.log) / [results](../../../.cache/coral-visual/results.json) | **40/40 steps, exit 0; 16/16 cases and four 2.0 font-ratio checks passed** on the aggregate's instrumented binary. |

The four workflow roots each include the 5 command-policy tests, the commit root
also includes the 5 conflict-policy tests shared with the stash root, and all roots
overlap with `git-unit`/`git-index-unit`; **94 is the sum of the four roots, not an
additive unique-test total**. Widget, fixture and native counts are separate harness
results with overlapping coverage, not a unique-test total. No aggregate wall time
is claimed. The native workflow suite covers commit staged-only/soft
uncommit/stage-tracked and their refusals, branch create/switch/delete (merged,
typed-name force, dirty protection), lightweight tags, worktree add/remove and path
validation, stash push/apply/pop/drop and dirty-buffer refusal, conflict
current/incoming/both resolution plus abort and rejection, remote push/fetch and
force-with-lease, history log/diff/blame/permalink (including local-remote refusal),
and hunk staging preservation and navigation. Its recorded limits: remotes are
**local bare paths over the file protocol only — no network is used**; permalinks
are constructed and declined, **no browser is launched**; read-only commands are
not a sandbox (local clean filters can execute).

**Safety fixes included in this final evidence:**

- **Stage tracked and commit** refuses unmerged conflicts before `git add -u`:
  `recheckStage` rechecks HEAD and the full status under the worker before apply,
  so a conflict is never silently staged or resolved.
- **Uncommit** refuses while a merge/rebase/cherry-pick/revert is in progress and
  writes through a compare-and-swap `update-ref HEAD <parent> <expected>`: a HEAD
  move since review fails closed instead of re-resolving `HEAD~1`; the reviewed
  parent is pinned, and index/worktree are never touched.
- **Refs, worktree and remote writes** hold the manager file-operation barrier;
  branch switch/delete additionally guard open documents (`guardTree`), and
  stash/conflict worktree-affecting writes refuse while an editor document is open
  under the repository (`openDocumentUnderRepo`); open documents are never saved.
- **Push** targets the fully-qualified current local branch refspec
  `refs/heads/<branch>` (never the upstream's branch name); the credential-helper
  disclosure names the exact remote and refspec, the approved action launches
  exactly that disclosed target, and detached/unborn HEAD is refused.
- **Conflict resolution publication wins over cancellation**: once the atomic
  replace renames, the worktree change is recorded/reported even if a close raced
  in; a write cancelled before publication warns that the worktree file is
  unchanged and refreshes Source Control.
- **Cancelled writes warn and refresh** rather than leaving a stale snapshot
  presented as current.

The visual matrix covers the **existing workbench**, not Source Control-window
visual parity; headless/offline Follow Pearl limitations remain. `test-m4-slice`
composes `git-unit`, `git-index-unit`, `git-workflow-unit`, native `git`, native
`git-workflows` and `test-m3` (M1/M2 regressions). It validated the implemented
core-workflow increments, **not full Zed/UI parity**; it predates the UI-parity
increment, whose targeted validation is recorded above and whose remaining limits
are listed in [UI parity delivered; remaining scope and limits](#ui-parity-delivered-remaining-scope-and-limits).

## Second-increment verification — historical standalone evidence

**Historical second-increment record; its aggregate remained pending and was never
accepted. The final core-workflow validation above superseded it as the accepted
core-workflow evidence.**

Recorded standalone results supplied for this increment:

| Evidence | Result |
| --- | --- |
| `git-index-unit` | **26 passed**, approximately **4 minutes**; disposable-repository transaction backend tests. |
| `git-unit` | **27 passed**; pure parser/display/command-policy root. |
| Final native report, `.cache/m4-index-native` | **46 passed**: **31 new mutation + 15 prior inspection** cases. |

The earlier original `teardown-root` open-workspace timeout is retained as a failed
attempt; it subsequently passed both isolated and in the full native run. **No code
fix or relaxed timeout** is credited for those retries. Counts are not additive
unique coverage. **Paused at the user's request: the aggregate was interrupted,
and the user requested skipping the remaining regressions. They are not verified,
not passing results.** No automatic rerun is planned during this pause.

Before interruption, `pearl/.cache/coral-m4-index-gate.log` recorded **46/46 native
Git cases**, **89 native language passes / 3 optional blocked**, a passing widget
suite, **25/25 fake-server fixture tests**, and **18/18 workspace compatibility
groups**. The last logged case was `canonical_symlink_save_reservation_alias` in
the multi-window suite. There is no final aggregate build summary. Current
hooks-disabled production and separate visual qualification are also not claimed.
Do not promote the historical gate below to current-increment acceptance.

Resume checkpoint: selected full-file Stage/Unstage and review are implemented;
no hunk staging or commits are enabled. The next implementation slice is hunk
review/staging, with this explicitly unverified regression remainder carried forward.

## Final first-slice validation — passed

**Historical read-only increment only; not validation of the second increment.**

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
zig build git-index-unit -Doptimize=safe -j1
zig build git-workflow-unit -Doptimize=safe -j1
zig build git -Doptimize=safe -j1 -- --aqueous-prefix /usr
zig build git-workflows -Doptimize=safe -j1 -- --aqueous-prefix /usr
zig build test-m4-slice -Doptimize=safe -j1 --summary all
```

`git-unit` uses `src/git_tests.zig`; `git-index-unit` uses `src/git_index_tests.zig`
for the backend; `git-workflow-unit` runs the four disposable-repository roots
`src/git_commit_tests.zig`, `src/git/refs_test.zig`, `src/git/stash_test.zig` and
`src/git/remote_test.zig`. `git` uses the private native `tests/git.py` harness, its
`tests/git_mutations.py` cases and instrumented binary; `git-workflows` uses
`tests/git_workflows.py` on the same instrumented binary. `/usr` is this host's installed test-tool
prefix; use a prepared fixture prefix on other hosts. The harness uses disposable
repositories/private Wayland, D-Bus and HOME/XDG state, not the user's repository;
fixture setup commits/stages only inside those disposable repositories. Its bounded
clean-filter cancellation cases deliberately exercise the disclosed helper boundary,
not a sandbox guarantee.

`test-m4-slice` composes **Git pure units + index-transaction/hunk backend units +
the four workflow unit roots + native inspection/mutation Git + native workflow
acceptance + `test-m3`**, including M1/M2 regressions. It covers the implemented
inspection/index/workflow increments, **not full Zed/UI parity**. Its final parent
aggregate **passed 117/117 steps with 475/475 Zig tests, exit 0**; see
[Final M4 core-workflow validation](#final-m4-core-workflow-validation--accepted).

Implementation map: `src/git/status.zig` (bounded parser/labels),
`src/git/command.zig` (inspection argv/environment/preview policy),
`src/git/env.zig` (explicit write/network environment allowlists),
`src/git/controller.zig` (window, discovery, selection, hunk navigation, snapshots
and lifetime), `src/git/hunk.zig` (bounded unified-diff parser and strict
snapshot applier), `src/git/mutation_controller.zig` (full-file/hunk review,
admission/barrier and worker lifecycle), `src/git/index_transaction.zig` and
`src/git/index_transaction_os.zig` (checked single-path publication and Linux
descriptor boundary), `src/git/commit.zig` + `commit_controller.zig`
(commit/stage-tracked/uncommit), `src/git/refs.zig` + `refs_controller.zig`
(branches/tags), `src/git/worktree.zig` + `worktree_controller.zig`
(list/add/remove/open handoff), `src/git/stash.zig` + `stash_controller.zig`,
`src/git/conflict.zig` + `conflict_controller.zig`, `src/git/remote.zig` +
`remote_controller.zig`, `src/git/history.zig` + `history_controller.zig`, with
App/workspace-policy and menu/palette integration in their existing modules.
