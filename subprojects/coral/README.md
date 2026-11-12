# Coral

A standalone Linux text editor written in **Zig 0.17.1 and GTK4**, with
GtkSourceView editing and offline Enchant spell checking. Its native foundation
includes independent editor groups, editable source excerpts and crash recovery,
with Pearl appearance. Multi-root workspaces include a bounded virtualized explorer,
Quick Open, streaming text search, movable native Explorer/Search docks, safe
settings with provenance, and explicit persistent workspace trust. Automatic project
and scratch-window snapshots, ordinary multi-window startup, native recent-project
and buffer pickers, and reviewed workspace-root management complete **M2 implementation**
for the bounded workspace preview. Explicit saved checkpoints remain separate.
Reviewed Explorer operations provide bounded create/rename/move/permanent-delete
workflows. **The bounded M3 baseline is complete; detected-language automatic
startup is implemented and validated within its documented limits.** Approved local
language servers start automatically in trusted, unpaused workspaces and provide
command-driven features, diagnostics, semantic tags and reviewed edits.
**M4 Git/review core workflows are implemented and validated:** the native Source Control window provides
status/refresh, diff previews, **selected full-file and single-hunk
staging/unstaging with separate checked review**, and the remaining core workflows
as command-driven native dialogs: staged-only commit (plus explicit stage-tracked
and commit, and soft uncommit), branches/lightweight tags, worktrees, stash,
conflicts with continue/abort, remotes, and history/blame/permalinks. This is not
dock/editable-Project-Diff UI parity or full Zed parity; the parent aggregate,
hooks-disabled production and separate visual gates passed. Agent services remain later work. See
the [M3 language guide](docs/WORKBENCH_M3_LANGUAGE.md) and
[M4 Git guide](docs/WORKBENCH_M4_GIT.md).

![Native Coral editor](artifacts/native/editor-dark.png)

## Build and run

Use Zig 0.17.1, `pkg-config`, a C toolchain, GTK **4.12+**, GtkSourceView **5**,
Enchant **2**, and their development headers. GTK 4.24.1, GtkSourceView 5.22.0,
and Enchant 2.8.21 are the current tested versions. Older supported API baselines have
not been tested in a separate distribution image.

```sh
cd subprojects/coral
zig build -Doptimize=safe
zig build run -- /path/to/notes.txt
zig build test
```

The executable is `zig-out/bin/coral`. The build stages its desktop entry, icon,
AppStream metadata, and two editor color schemes under `zig-out/share/`.
Use `zig build --prefix PATH` to stage elsewhere. `zig build run` can find styles
in the source checkout; an installed application reads them relative to its
executable. Coral does not require a running Pearl shell or Aqueous compositor.

Pearl's `pearl`, `pearl-git`, and `pearl-intel-git` PKGBUILDs build, test, and
bundle Coral. The release package supplies `coral`; both Git packages supply
`coral-git` (**Coral Git**, application ID `org.aqueous.Coral.Git`). Build that
variant directly with `zig build -Dgit-variant=true`. Each variant has its own
launcher, metadata, icon, and installed styles (`share/coral/styles` or
`share/coral-git/styles`), allowing stable and Git packages to coexist.
Preferences and personal dictionaries are shared between the variants.

Spell checking requires an installed Enchant provider and language dictionary.
`enchant-lsmod-2 -list-dicts` lists available languages. This development host
uses Shelly; repository PKGBUILDs do not identify the host distribution.
No dictionaries were installed for this work; verification
uses an isolated test dictionary. Missing dictionaries leave editing usable and
show **Dictionary unavailable**. Choose an available language in Preferences.

Options: `--workspace PATH`, `--folder PATH`, `--follow-pearl`, `--light`, `--dark`,
`--native-theme`, `--width=N`, `--height=N`,
`--log-level LEVEL`, `--log-scopes LIST`, `--help`, `--version`, followed by
local filenames or local file URIs. Diagnostics share Pearl's log handler and
land wherever stderr goes; see [logging](../../docs/LOGGING.md).

## Workspaces — M2 implementation complete, bounded preview

Choose **Open Folder…** or **Open Workspace…** from the menu or command palette,
or launch `coral --folder PATH` / `coral --workspace PATH`. A workspace file is
versioned JSON, for example:

```json
{
  "version": 1,
  "roots": [
    {"name": "Frontend", "path": "./frontend"},
    {"name": "Backend", "path": "./backend"}
  ],
  "exclude": ["build/", "**/*.tmp"]
}
```

Relative roots resolve beside the manifest. Root-qualified tabs distinguish
identical filenames. The virtualized expandable explorer reads children lazily,
applies nested `.gitignore` and explicit excludes, and batches live updates for
accessed directories. **Roots / Back / Rescan / Close workspace / Reset tree**
provide navigation and recovery from capacity limits. Switching roots preserves
open edits. Unavailable roots are shown, never created.

**Load more** replaces the current 256-entry page window; pages are sorted
individually, not globally. Storage is bounded to 64 directory states, eight
resident pages and 1 MiB of page arenas. Native acceptance reached all 100,000
files across 391 pages with bounded widgets/memory. Watch failures show a manual
Rescan fallback; ignore-policy errors fail closed.

**Ctrl+P** opens the fuzzy file picker; **Ctrl+Shift+F** searches text across roots.
Results stream into a virtualized list, honor ignore/exclude rules, and use dirty
buffer contents instead of stale disk text. Enter opens the selected result in
the active editor group. Search is literal, case-insensitive and bounded to 1,024
text results / 128 ranked paths; omissions are visible. These are snapshots, not
a continuously monitored recursive index—use **Refresh** for unmonitored changes.
See [search usage, limits and 100k validation](docs/WORKBENCH_M2_SEARCH.md).

Workspace manifests and root-local `.coral/settings.json` can set `lines`, `wrap`,
`spaces` and `indent`, with language overrides. Resolution is defaults → explicit
user → workspace → folder → language overrides. **Workspace: Settings and Trust…**
shows effective values and their origins. **Rescan** adopts updated folder settings;
repository values never overwrite user preferences.

Workspaces start **restricted**. **Trust workspace…** requires confirmation and
persists an exact machine-owned approval; **Workspace: Revoke trust** invalidates
permits for matching workspace scopes across this process immediately and removes
the approval asynchronously. Trust is not
blanket tool permission and starts no services. See the [settings/trust guide](docs/WORKBENCH_M2_POLICY.md)
for filesystem identity requirements, storage errors and revocation limits.

**Save Workspace Session** / **Restore Workspace Session** in the palette persist
one explicit checkpoint of roots, tabs, groups, excerpts, view state and dock layout. Clean files
rebind only after verification; dirty/conflicting/unavailable files become unsaved
copies. Existing documents stay intact. Close an active workspace before restoring.
This explicit slot is never overwritten by automatic sessions; later Discard does not
remove it. See [explicit session usage and safety limits](docs/WORKBENCH_M2_SESSIONS.md).

Automatic project/latest per-window snapshots also retain scratch windows. Ordinary
launch without file/folder/workspace arguments restores the startup set. Explicit CLI
inputs and real recovery decisions take precedence and suppress old startup membership
without deleting recents; empty recovery directories do not suppress startup.
**Open Recent Project… (Ctrl+Alt+P)** activates a matching live owner or restores an
independent window. Open Folder/Workspace keeps current documents and durably retires
the old project state; it does not swap isolated same-window tab sets.
**Open Buffers… (Ctrl+Shift+O)** selects this window's full/excerpt views by identity.

Automatic close freezes layout/text before prompts, reconciles successful Save and
excludes Discarded documents; Cancel/failure thaws surviving windows. Over **4 MiB per
document / 8 MiB total text**, explicit **Close without automatic session** still
requires normal Save/Discard and durably clears old startup membership before closing.
The catalog is bounded to **64 records / 16 startup members / 256 MiB**, with cross-process
leases, generation-checked Forget confirmation and no silent dirty eviction. Picker
snapshots have at most **512 items / 50 displayed matches**, not unlimited history access.
See [automatic projects, close safety and pickers](docs/WORKBENCH_M2_PROJECTS.md).

For folder-only workspaces, choose **Save Workspace As…** to a new destination first.
Then **Workspace: Add Folder…** selects an existing directory, and **Workspace: Remove
Selected Root…** removes the selected root from the manifest—not from disk. Each action
requires review and writes immediately; open documents survive, and the last root
cannot be removed. Supported settings/excludes/names and absolute lexical path meaning
are preserved. Source bytes/etag are revalidated; existing Save As destinations are
refused. Dedicated root rename/reorder controls are not implemented. See
[reviewed root management](docs/WORKBENCH_M2_PROJECTS.md#reviewed-workspace-root-management).

Explorer and Search can be docked **left, right or bottom**, resized, hidden and
focused from the activity rail or palette. **Ctrl+B** toggles Explorer; **Ctrl+1**
returns to the editor. Quick Open is a transient overlay sharing Search's query
and results. Compact windows retain one auxiliary panel and preserve the desired
wide layout. See [dock controls and validation](docs/WORKBENCH_M2_DOCKS.md).

**Ctrl+Shift+N** opens an independent window; **Ctrl+Shift+W** closes its window,
and **Ctrl+Q** quits all windows with sequential dirty-document prompts. Each window
owns its documents, workspace, search and docks. User preferences are shared;
same-file buffers are independent, with coordinated in-process saves and disk
conflict checks. See [multi-window usage and limits](docs/WORKBENCH_M2_WINDOWS.md).

Select an Explorer entry, then use its buttons, menu or **Explorer:** palette commands
for **New file… / New directory… / Rename… / Move… / Delete permanently…**. Input
and worker preparation do not write: **all five kinds require explicit review confirmation**.
Creates are exclusive and do not auto-open; moves stay within one root/filesystem;
delete is permanent, regular-file/empty-directory only, with no trash, undo or recursion.
Restricted workspaces permit these explicit edits without running tools. All affected
open documents, **clean or dirty in any window**, must be resolved and closed first.
Any unavailable root or root/manifest lexical `..` in any open process workspace blocks
all mutations with `WorkspaceBusy`; close that workspace or reopen verified available,
normalized/canonical paths—never blindly collapse `..`. See the [file-operation guide](docs/WORKBENCH_M2_OPERATIONS.md)
for path checks, process-wide barriers and best-effort external-race limits.

**M2 implementation is COMPLETE as a bounded workspace preview, not a full IDE.**
Persistent indexing and workspace-wide replace remain outside this preview. Crash
recovery still restores documents/layout but not roots; automatic projects and explicit
checkpoints are separate mechanisms. See [workspace usage](docs/WORKBENCH_M2_WORKSPACES.md)
and the [M2 acceptance audit and validation checkpoint](docs/WORKBENCH_M2_ACCEPTANCE.md).

## Language intelligence — automatic startup implemented and validated

Open a saved file in a workspace and explicitly approve **Workspace: Settings and
Trust…** (or restore a valid exact prior trust grant). Detected-language discovery
runs after open, project/session restore, successful Save/Save As and language
changes. In a trusted, unpaused workspace, an exactly approved server starts
automatically; a new or changed approval key gets one first-use prompt to review
its executable identity, arguments, effective environment and root cwd.
**Language: Stop all sessions** persistently pauses the workspace after successful
publication; **Start… / Restart current server** resumes it with fresh checks.
Decline/crash does not cause a prompt/restart loop; use Start/Restart to retry.
Unknown/unconfigured languages do not launch or offer installation.

The default is exactly
**`/usr/bin/zls` (tested ZLS 0.17.0 with Zig 0.17.1)**. Optional user-owned configuration
is **`~/.config/coral/languages.json`**, not repository settings; checked config
parents must not be symlinks and identity checks require filesystem birth time.
A server has user-level filesystem/network permissions, **not an OS sandbox**.
No automatic downloads or installation are provided.

Approval-key **v2** binds selected argv/effective environment/root-cwd policy,
config-file/ancestor incarnation and resolved executable identity metadata, not
every unrelated raw config byte. The raw config digest is separately checked
fresh. A verified fd travels through transport to **`execveat`**, with final metadata
revalidation; this is not immutable content, and mutable interpreters/dependencies
remain a limit. Separate machine state lives in **`$XDG_STATE_HOME/coral/language`**
(default `~/.local/state/coral/language`), not workspace trust or session state.
It allows **128 approved keys and 128 workspace-pause keys**, with no eviction;
errors fail closed. Stop's `Busy` publication retries retain intent with a **1 s
backoff cap**, not an attempt cap. Nonretryable failure reports an error and keeps
a local inhibit, but cannot promise durability across relaunch. See the guide for
additional 128-entry bookkeeping limits and persistence/identity boundaries.

The **Language:** commands cover completion, hover, signature help,
definition/declaration/type definition/implementation, references, document and
workspace symbols, Problems, document/selection formatting, rename and code
actions, plus Start/Stop/Restart/Status. Semantic tokens have real full/delta native
tags with **manual refresh**; inlay hints use a **position picker, not inline hints**.
Code-lens/server commands and external HTTP(S) links require separate confirmation.
Problems aggregates **synchronized open documents** across this window's sessions.
There is one session per owning root/language, up to **eight per window**.

Navigation and edits stay within the session's **same owning root**, so external
dependency/standard-library and peer-root navigation are refused. Text changes are
reviewed, revision-checked **grouped undo transactions with no autosave**. A single
standalone create/rename/move/delete resource proposal instead uses the reviewed
Explorer worker for a **real disk mutation with no undo**; mixed/batch operations,
overwrite, ignore options and recursion are refused. Static filtered did-file
notifications are supported, not dynamic registration or will-operation requests.

**Snippet support is advertised false.** Defensive flattening of unsolicited safe
snippet syntax is not interactive snippets; those remain M8 advanced editing.
Unknown/unconfigured languages and excerpt-origin service requests are refused.
See the [complete commands, configuration, lifecycle/size limits and evidence](docs/WORKBENCH_M3_LANGUAGE.md),
including the native **8 MiB input / 4 MiB output queues per session** and separate
4 MiB protocol-message limit. Eight sessions reserve at most **96 MiB in queues**,
excluding snapshots, worker stacks and other storage. Versions advance only on
successful sync; an oversized-sync failure stops once with a stable error.
There are no placeholder service panels or full-IDE parity claims.

## Git — Source Control and core workflows, M4 core validated

Use the **Git** menu or palette: **Git: Source Control…**, **Git: Refresh
repositories**, **Git: Unstaged diff**, **Git: Staged diff**, **Git: Stage selected
file…**, **Git: Unstage selected file…**, **Git: Stage selected hunk…**, **Git:
Unstage selected hunk…** and **Next/Previous hunk**, plus the workflow commands
below. A **separate native
window**, not a dock or editable Project Diff, shows repository/root selection,
branch/status, paged paths and noneditable **index → disk / HEAD → index** previews.
Git requires a trusted workspace **and per-window subprocess disclosure approval**;
there is no Git execution at startup or in restricted mode. The initial read-only
disclosure does **not** authorize writes or queue a mutation. Select an actual
Source Control status row, not an editor buffer, then request a separate **FULL FILE,
NOT HUNKS** review — or a **ONE HUNK, NOT THE WHOLE FILE** review for the selected
hunk. Complete escaped before/after bytes, existence, modes, byte counts
and SHA-256 digests must be explicitly approved. Stage replaces that index path with
captured disk bytes; unstage restores HEAD (or removes the entry when absent).
Hunk applies use a strict captured-snapshot applier (exact position, byte-identical
context, no fuzz/offset) and preserve all other hunks/paths; **absent sides and mode
changes are refused**. **Dirty buffers are allowed, excluded and never saved.**

Worker-only prepare performs no repository writes. Apply requires valid trust,
generations/selection and the manager operation barrier; it rechecks the full index,
HEAD/ref, root/Git-dir bindings and selected disk snapshot. Exclusive `index.lock`
ownership, a verified single-path private-index proposal and stat-cache invalidation
preserve unrelated logical entries/worktree changes. The target loose blob and its
directories are fsynced before index publication. Foreign locks are never deleted;
every attempt consumes approval. Post-publication cancellation is success; final
Git-directory fsync failure means **published, durability uncertain**, not safe retry.
Aborted apply may leave an unreachable blob, but never changes worktree files.

Mutation limits: **256 KiB regular UTF-8 text**, **16 MiB index**, and per-side review
of **256 KiB escaped display / 4,000 lines / 2,048 source bytes per line**. Refusals
include binary/symlinks, conflicts, sparse/split/v4/extended indexes, staging conversion
attributes (even explicit `-text`) and enabled/`input` `core.autocrlf`. Packed/alternate-only
target blobs refuse with `ObjectDurabilityUnavailable`; this is not generic all-repo
support. Protection assumes cooperative writers, not malicious same-UID processes,
mount aliases or adversarial refs in the final recheck/publication window.

Discovery probes workspace roots and the active saved file's parent, not every
nested directory. Repository top-levels outside their owning root are refused.
`.git` files and existing linked worktrees are supported for reads, **not worktree
operations**. Limits: **8 repositories, 1 MiB status / 10,000 entries, 128 rows per
page**; diffs capture at most 1 MiB and preview at most **256 KiB / 4,000 lines /
2,048 bytes per line**, with **15-second per-command timeouts**. Inspection refresh
is manual; attempted mutations invalidate/refresh status. Status/diff are not atomic
with external disk/index changes. Unsaved buffers are
excluded and never saved or staged. Rename detection is disabled (add/delete),
submodule contents excluded, unborn/detached HEAD supported, and invalid UTF-8
status paths refused.

Requires **Git 2.31+ at `/usr/bin/git`**. Inspection uses fixed argv/config and a
replacement environment disabling system/global config, prompts, credential helpers,
external diff/textconv and Git protocol access; workflow writes and network
operations use the separate disclosed policies described below. **Not a sandbox:**
repository-local clean filters/programs can still execute with user permissions; no
guarantee of no arbitrary filter writes or network activity is made.

**Core workflows (third increment), all command-driven native dialogs:**

- **Commit staged…** commits only the reviewed staged index with a typed message
  (`commit -F -`; no `-a`/`--allow-empty`; empty staged set refused). **Stage tracked
  and commit…** explicitly reviews `git add -u` (never untracked files; unmerged
  conflicts refused before staging), then the resulting staged set. **Uncommit
  last…** is a soft reset via compare-and-swap `update-ref HEAD` keeping
  index/worktree; **initial, merge, published HEAD and in-progress operations are
  refused**.
- **Branches… / Create branch… / Switch branch… / Delete branch…**: switch never
  forces; delete verifies merged, and unmerged force-delete requires typing the exact
  branch name in a separate confirmation; dirty worktrees block switch/delete with an
  explicit cancel-or-stash choice. **Tags…** lists read-only; **Create lightweight
  tag…** creates at HEAD (no annotated tags, signing or deletion).
- **Worktrees… / Add worktree… / Remove worktree…**: add validates paths inside the
  owning root and one worktree per branch; remove is clean-only (never `--force`);
  Open hands off to a parent callback or messages the path when none is installed.
- **Stash push… / list… / apply… / pop… / drop…**: named tracked/staged/all push
  (staged needs Git ≥ 2.35; ignored files never stashed); apply preserves the entry;
  pop drops only after a successful apply plus separate confirmation; a failed apply
  preserves the entry; drop is confirmed.
- **Conflicts…** lists unmerged paths and base/ours/theirs stages; **Resolve conflict
  using current/incoming/both…** writes reviewed bytes to the worktree then stages;
  publication wins over cancellation, and a write cancelled before publication warns
  and refreshes. **Manual, binary and rename/delete conflicts are refused.**
  **Continue/Abort merge/rebase…** act on gitdir-detected merge/rebase/cherry-pick/revert
  state, never marker guesses.
- **Remotes… / Fetch… / Pull… / Push… / Force push with lease…** run only after a
  separate **credential-helper disclosure**; pull defaults to ff-only (merge/rebase
  explicit); push targets the disclosed current local branch refspec
  (`refs/heads/<branch>`) and refuses detached/unborn HEAD; push is never backgrounded.
- **File history… / Blame… / Commit diff… / Open permalink…**: bounded read-only
  inspection; GitHub/GitLab/Codeberg https permalinks are strictly validated and
  opened in the user's browser only after external-link confirmation. **No PR API.**

Workflow writes use your Git identity/config; hooks/signing (and, for network
operations, credential/askpass helpers) may execute — **not a sandbox**. Stash
push/apply/pop and conflict continue/abort refuse while unsaved buffers exist under
the repository. **UI parity limits:** no source-control dock, editable Project Diff,
split/word-diff, tree/flat or file/section/all staging parity; packed-only target
blobs still refuse with `ObjectDurabilityUnavailable`. See the
[Git guide](docs/WORKBENCH_M4_GIT.md) for exact policy, refusals and evidence.

**Final M4 core-workflow evidence (accepted):** `zig build test-m4-slice
-Doptimize=safe -j1 --summary all` passed **117/117 steps, exit 0**, with **475/475
Zig tests passed (no skips reported)** ([gate log](../../.cache/coral-m4-final-gate.log)).
Unit roots: `git-unit` **27**, `git-index-unit` **40**, `git-workflow-unit` **94 across
four roots (commit 25 + refs 30 + stash 18 + remote 21)**, superseding the earlier 81.
Native `git` **46 / 0 / 0** ([results](../../.cache/coral-git/results.json)) and native
`git-workflows` **36 / 0 / 0** ([results](../../.cache/coral-git-workflows/results.json)),
both `complete_suite: true`; language **89 / 0 / 3 optional blocked**, lifecycle
**20/20**, widgets **204/204 in 47.928 s**, fixture **25/25**, and full M1/M2
regressions passed. [Hooks-disabled production](../../.cache/coral-m4-final-production.log)
passed **46/46 steps**; [visuals](../../.cache/coral-m4-final-visual.log) passed
**40/40 steps, 16 cases and four 2.0 font ratios** on the aggregate's instrumented
binary (existing-workbench coverage, not Git-window visual parity). Workflow fixtures
use local bare remotes over the file protocol (no network) and construct/decline
permalinks without launching a browser. Safety fixes included: stage-tracked unmerged
refusal, uncommit operation guard + CAS `update-ref`, refs/worktree/remote barriers
and open-document guards, disclosed current-local-branch push refspec with
detached/unborn refusal, conflict publication-wins, and cancelled-write
warnings/refresh. `test-m4-slice` composes all Git unit roots, both native suites and
M1/M2/M3 regressions; it validates the implemented core workflows, **not full Zed/UI
parity**.

**Historical read-only gate:** `test-m4-slice` passed **105/105 steps, exit 0**, with **586/587 Zig tests
passed / 1 expected non-root trust-test skip** (not a pass), including **27 Git,
129 language and 340 main-root passes**. Final native Git passed **15/15**;
language **89 passed / 0 failed / 3 optional blocked** (servers not installed),
lifecycle **20/20**, widgets **204/204 in 36.993 s**, fixture **25/25**, and full
M1/M2 regressions passed. The aggregate includes the Unicode display-helper fix.
[Production](../../.cache/coral-m4-readonly-production.log) passed **46/46 steps**;
[visuals](../../.cache/coral-m4-readonly-visual.log) passed **40/40 steps**, **16 cases
and four 2.0 font ratios**, both exit 0. Visuals cover the existing workbench,
**not Git-window visual parity**. See [final evidence and the retained earlier
standalone 15-case run](docs/WORKBENCH_M4_GIT.md#final-first-slice-validation--passed).
These are first-read-only-slice gates, **not completed M4 acceptance**; counts are
not an additive unique-test total.

## Implemented

- Editable, reorderable document tabs; new/open/save/Save As; file arguments;
  canonical-path duplicate detection; dirty indicators and save/discard/cancel
  prompts for individual tabs and quitting.
- Asynchronous descriptor-checked local loads and GIO replacement saves. Etag
  conflicts and deleted files require a decision. Failed/cancelled saves retain
  edits. Edits made during a save stay dirty after the older revision finishes
  saving. Loading requires Linux `/proc/self/fd` for GIO-compatible metadata.
- Existing-file opens never create missing files or parent directories. Use
  **New document → Save As** to create a file, including when a CLI path is missing.
  Directories, FIFOs and devices are rejected; reloads use the same checked loader.
- External-file monitoring shows **Changed on disk** without replacing your edits.
  **Reload from Disk** in the menu/palette explicitly reloads; dirty documents
  require discard confirmation.
- Native **Command Palette** (`Ctrl+Shift+P`) with filtered, keyboard-accessible
  commands and focus restoration on cancellation.
- Independent equal-width editor groups: **Ctrl+\\** splits the current document;
  each view retains its own selection and scroll. Focus/close-group commands are
  available through the palette. Closing a duplicate view preserves its document.
- **Edit selection as excerpt** opens a source-mapped editable tab. Checked grouped
  buffer edits, grouped undo/redo and protected typing intervals prevent undoing
  only one participant in a multi-document change. Conflicting newer edits are
  refused. See the status report for conservative history-boundary limitations.
- Durable versioned recovery with explicit **Restore / Keep for later / Discard**,
  including groups, tabs, excerpts and selections. Restored text becomes unsaved
  copies, never automatic overwrites of source files.
- UTF-8 validation, BOM preservation, LF/CRLF and final-newline preservation,
  explicit mixed-line normalization, and rejection of binary/unsupported input.
- GtkSourceView syntax highlighting; Unicode editing; undo/redo; clipboard;
  literal case-insensitive find, match navigation, replace and replace-all;
  go to line; wrapping, line numbers, text size, indentation and spaces/tabs.
  Replace/replace-all and spelling corrections use revision-checked, undoable
  transactions; automated edit transactions are capped at 16 MiB per buffer and
  65,536 replacements, separately from the larger file-load limit.
- Offline spelling on a dedicated worker: Unicode/Pango word boundaries,
  underlines, up to five suggestions, undoable correction, document-local ignore,
  personal dictionary additions, and installed-language selection. Source code
  defaults to spelling off; Preferences can override the current document.
- Live Pearl appearance (Follow Pearl, the default): committed palette, variant,
  font and GTK theme mode reach the chrome through the shared appearance
  boundary, and the editor buffer follows through a generated GtkSourceView
  scheme under `$XDG_CACHE_HOME/coral/styles`. Pearl dark/light and native GTK
  remain as manual choices, narrow-window adaptation, keyboard
  operation, accessible control labels, and persisted preferences.
- Explicit presentation limits: syntax/automatic spelling are reduced at 524,288
  GTK characters or logical lines over 16 KiB. Giant lines offer a visible bounded
  excerpt editor rather than hanging on full-paragraph layout. That action is
  unavailable beyond the 16 MiB checked-edit cap. The separate >10 MiB load warning
  and 128 MiB read limit remain. See the measured tradeoffs in the status report.

Settings are stored in `$XDG_CONFIG_HOME/coral/preferences.ini` (default
`~/.config/coral/preferences.ini`). Personal words use Enchant's configuration
and may be shared with other Enchant applications.

Recovery journals live under `$XDG_STATE_HOME/coral/recovery` (normally
`~/.local/state/coral/recovery`). Recovery reaches the last durable checkpoint,
not necessarily the latest keystroke. Caps are **4 MiB per document / 8 MiB total
text / 12 MiB manifest**. An oversized open document rejects the whole new
checkpoint visibly; the previous checkpoint is retained. Save important work
explicitly—recovery is not a backup service.

| Shortcut | Action |
| --- | --- |
| Ctrl+N / Ctrl+O | New document / open existing file |
| Ctrl+Shift+P | Command palette |
| Ctrl+P | Quick Open workspace file |
| Ctrl+Alt+P | Open Recent Project |
| Ctrl+Shift+O | Open Buffers in this window |
| Ctrl+Shift+F | Search workspace text |
| Ctrl+\\ | Split editor group |
| Ctrl+S / Ctrl+Shift+S | Save / Save As |
| Ctrl+W / Ctrl+Q | Close tab / Quit All |
| Ctrl+Shift+N / Ctrl+Shift+W | New window / close window |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Ctrl+F / Ctrl+H | Find / replace |
| F3 / Shift+F3 | Next / previous match |
| Ctrl+G | Go to line |
| Ctrl+plus / Ctrl+minus / Ctrl+0 | Increase / decrease / reset text size |
| Ctrl+comma | Preferences |
| Shift+F10 | Spelling suggestions |
| Escape | Dismiss spelling/search and notices |

Right-click a flagged word for suggestions with Cut/Copy/Paste retained.
Right-click elsewhere for GtkSourceView's normal editing menu.

## Verification and design

The [workbench expansion plan](docs/WORKBENCH_IMPLEMENTATION_PLAN.md) targets a
VS Code-style workspace/editor with Zed-style agents and Git workflows.
The [native foundation status](docs/WORKBENCH_STATUS.md) records implemented
groups, excerpts, guarded undo, recovery, file monitoring and validation;
**M2 and the bounded M3 baseline have historical validation. The automatic-language
increment passed its separate acceptance gates. M4 Git/review core workflows
(hunk/full-file staging, commit/uncommit, branches/tags, worktrees, stash, conflicts,
remotes, history/blame/permalinks) are implemented and validated: the parent
aggregate, hooks-disabled production and separate visual gates passed. The read-only
aggregate and second-increment evidence remain historical. Explicit UI-parity limits
remain and full Zed/UI parity is not claimed.
Production terminal and agent UI remain unimplemented**. See the
[M4 verification status](docs/WORKBENCH_M4_GIT.md#final-m4-core-workflow-validation--accepted).
Explore the separate [interactive workbench prototype](docs/mockups/workbench/index.html)
and its [interaction guide](docs/mockups/workbench/README.md). All prototype
operations stay in memory; they are not native feature evidence.

Read the [implementation report](docs/IMPLEMENTATION_STATUS.md) and
[native screenshot gallery](artifacts/native/README.md). Native integration
uses Pearl's existing private Wayland harness, temporary XDG directories and
files, and a small pinned Hunspell fixture:

```sh
zig build integration -Doptimize=safe
```

The harness needs the prepared `.cache/aqueous-activity-production` prefix,
Python, D-Bus, `wtype`, `wlr-randr`, and `grim`. Pass
`-- --aqueous-prefix PATH` for an alternate prefix. These are test dependencies,
not application dependencies. Integration builds a separate instrumented binary;
normal builds omit its test controls. `-Dnative-python=/absolute/path/to/interpreter-or-launcher`
selects a validation harness launcher (default `python3`). See the
[validation environment](docs/WORKBENCH_M2_ACCEPTANCE.md#this-hosts-private-icu78-recovery)
for this ICU79 host's exact private cached ICU78 recovery for its older libxml2 dependency;
no host packages or hardcoded production dependencies were changed.

Run the complete M1 correctness suite (unit, widgets, native workflows, groups
and crash recovery), or individual display-backed checks:

```sh
zig build test-m1 -Doptimize=safe -j1
zig build test-m2-slice -Doptimize=safe -j1
zig build test-m2-explorer -Doptimize=safe -j1
zig build test-m2-search -Doptimize=safe -j1
zig build test-m2-policy -Doptimize=safe -j1
zig build test-m2-sessions -Doptimize=safe -j1
zig build test-m2-docks -Doptimize=safe -j1
zig build test-m2-windows -Doptimize=safe -j1
zig build operations -Doptimize=safe -j1
zig build test-m2-operations -Doptimize=safe -j1
zig build project-unit -Doptimize=safe -j1
zig build projects -Doptimize=safe -j1
zig build roots -Doptimize=safe -j1
zig build test-m2-projects -Doptimize=safe -j1
zig build test-m2-roots -Doptimize=safe -j1
zig build test-m2 -Doptimize=safe -j1
zig build language-unit -Doptimize=safe -j1
zig build language -Doptimize=safe -j1
zig build language-lifecycle -Doptimize=safe -j1
zig build test-m3 -Doptimize=safe -j1
zig build git-unit -Doptimize=safe -j1
zig build git-index-unit -Doptimize=safe -j1
zig build git-workflow-unit -Doptimize=safe -j1
zig build git -Doptimize=safe -j1
zig build git-workflows -Doptimize=safe -j1
zig build test-m4-slice -Doptimize=safe -j1
zig build widgets -Doptimize=safe -- --aqueous-prefix /usr
```

`/usr` is the installed-tool prefix used for this host's foundation validation;
use the prepared fixture prefix on other setups. See the [status report](docs/WORKBENCH_STATUS.md#validation-completed)
for all commands and current acceptance limits. `test-m2` composes the prior nine
aggregate gates plus projects and roots, including M1 regressions. Confirmed
historical M2 project/root evidence is **25/25 projects and 18/18 roots**, with the nine prior gates
rerun successfully (**198 widgets** in each widget-including gate). Exact coverage,
the retained widget-timeout/retry caveat and the final consolidated run's checkpoint
are in the [M2 acceptance audit](docs/WORKBENCH_M2_ACCEPTANCE.md).

### Automatic-increment validation — accepted

The final [automatic-language aggregate](../../.cache/coral-auto-language-m3-retry.log)
passed **101/101 steps, exit 0**: all **17 Python invocations fresh**, all **11 Zig
runners cached from prior passes**. Native language passed **89 mandatory / 0 failed /
3 optional blocked** (missing clangd, TypeScript and pyright); pinned real ZLS passed.
Lifecycle passed **20/20**, full M1/M2 regressions passed, widgets passed **204/204 in
41.159s**, and the fake-server fixture passed **25/25**. Nine deterministic pause tests
passed **inside** one language case, not as extra native cases.

The [initial aggregate](../../.cache/coral-auto-language-m3.log) remains a failure:
**86/101 steps; 381/382 tests**, with **334 main-root passes + 1 ABRT** in the concurrent
capture watchdog. The [separate retry](../../.cache/coral-auto-language-test-retry.log)
passed **50/50 steps and 335/335 fresh main-root tests** before the final aggregate;
this is not a watchdog fix. [Hooks-disabled production](../../.cache/coral-auto-language-production.log)
passed **46/46 steps**; [visuals](../../.cache/coral-auto-language-visual.log) passed
**40/40 steps, 16/16 cases and four 2.0 font ratios** on the aggregate's instrumented
binary. See the [accepted evidence and limits](docs/WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted)
for unit-root freshness, retained reports and visual qualification boundaries.
No aggregate wall time or new paint-latency qualification is claimed.

### Historical M3 baseline validation

**Historical frozen-source M3 validation passed after the queue/sync fix, before
the automatic-lifecycle increment; these counts do not validate that increment:**
`zig build test-m3 -Doptimize=safe -j1 --summary all` completed **99/99 steps**, exit 0,
in **28m23.163s** within a 40-minute bound (**36 fresh successful / 63 cached steps**).
The main Zig root passed **334 fresh tests**; nine other runners were cached,
including the five pure language suites already run directly and freshly:
**102 tests = 16 protocol + 20 transport + 36 client + 27 features + 3 file-operation**.
All **17 Python harness/fixture invocations ran fresh**: **75 mandatory language
cases passed / three optional blocked** (clangd, TypeScript, Python), **20 lifecycle
groups**, **271 M1/M2 native groups**, **204 widgets in 42.099s**, and **25 fixture tests**.
Five capacity cases cover full/incremental 128 KiB and 1 MiB Unicode synchronization
and oversized-message stable-error handling. Counts overlap, not unique-test totals.

Hooks-disabled production passed **46/46 steps** (**three fresh / 43 cached**), with
fresh executable compilation in **30.053s**. Separate visuals passed **16 cases plus
four font-ratio checks before the final queue/sync-only change**, not on the final
binary; a secondary-panel footer still ellipsizes/clips at 390px. Native harness
reaping assertions passed, but no final baseline cleanup scan was done. Observed
fake-server end-to-end samples of **67–133ms** are not paint latency or validation of
the unmeasured **50ms** target.

See [historical M3 logs, binary hashes and retained earlier failures](docs/WORKBENCH_M3_LANGUAGE.md#final-validation-passed).
`pearl/.cache/coral-m3-complete.log` is authoritative for that historical baseline,
not earlier `full`, `final` or pre-capacity `accepted` attempts. The missing-root diagnostic/menu assertions
and lifecycle transcript cross-run contamination were corrected; their history
remains documented. At that checkpoint, native results contained the complete **75/0/3** matrix,
with retained `run-r_olc__s` evidence. Tests use private local fixtures, no downloads
or network-service tests.

**Historical file-operation-increment final validation passed:**
all **25 native scenarios together**, all **nine aggregate gates** sequentially with
600-second bounds, and a fresh hooks-disabled production build (**46/46 steps;
25-second executable compilation**). Each of eight widget-including gates executed
191 tests; four headless runners were cached on the final rerun. Earlier fresh
validation passed 305 main-root tests, including 23 operation-backend tests and manager
tests (overlapping counts). The initial 22 native scenarios and three added alias-review
scenarios also passed in separate historical runs. No final regressions, timeouts or
leaked test-session processes were reported. See the [operations validation](docs/WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09),
[gate logs](../../.cache/coral-operations-validation-logs/),
[production log](../../.cache/coral-operations-validation-logs/final-build.log) and
[native results](../../.cache/coral-operations/results.json). Those counts describe that
increment, not validation of the automatic-language increment.

The [original plan](docs/IMPLEMENTATION_PLAN.md), [interactive mockup](docs/mockups/index.html),
and [mockup gallery](docs/mockups/README.md) remain design references. They do
not replace the native test evidence.

Unlimited session history, cross-window tab transfer, remote files, legacy encodings,
grammar checking, general build/debug tooling and plugins are outside this preview. The user accepted M0's
bounded-editor tradeoffs to proceed to M2. Full giant-line rendering remains
unsupported and original input-to-paint targets remain unverified; acceptance
does not change the recorded measurements.
Markdown code fragments
are checked as text. Physical IME and screen-reader qualification remain manual
follow-up work; see the implementation report for precise limits.
