# Workbench M0 references, decisions, and acceptance handoff

> **Historical research/handoff:** the implementation and assignment audit below describes the inspected baseline, not the current tree. See [current status](WORKBENCH_STATUS.md), [benchmark results](WORKBENCH_M0_BENCHMARKS.md), [native terminal evidence](WORKBENCH_M0_TERMINAL.md), and [executed UX review](WORKBENCH_M0_UX_REVIEW.md) for subsequent delivery and remaining signoff. The upstream reference pins remain the frozen targets.

Research date: **2026-11-08**. Scope: read-only upstream/source research and this new document. This is a frozen reference specification and implementation handoff, **not an M0/M1 completion report**. The requested outcome remains complete M0 and M1, not another foundation-only batch.

## 1. Evidence boundary

Performed for this document:

- Queried upstream GitHub releases and resolved release tags to full commits; read the commit-pinned documentation listed below.
- Downloaded the selected reference text/schema files into memory and computed their SHA-256 hashes. No upstream implementation was copied into Coral.
- Ran `command -v zls` and `zls --version`: `/usr/bin/zls`, **0.17.0**. This proves installed version availability, not binary provenance or Coral LSP interoperability.
- Ran `pkg-config --modversion gtk4 gtksourceview-5`: **4.24.1 / 5.22.0**. These are observed local versions, not newly qualified minimums.
- Read the current workbench plan/status, prototype interaction guide, and the existing shared-buffer view implementation.

**Not performed:** launching/testing the full Zed binary, running Coral native/widget/unit tests, running benchmarks, running the browser prototype, exercising ZLS as an LSP server, or launching a provider/ACP adapter. Existing reports remain attributed historical evidence, not tests rerun by this researcher. Source documentation review is not proof of runtime behavior; upstream default-keymap entries are not evidence that every context/override was exercised.

M0/M1 can be validated locally with deterministic fixtures. **No live external provider, account, subscription, API key, paid request, or agent download is required for M0/M1.** The plan's real opt-in provider gate belongs to M6; its two pinned ACP adapters belong to M7. Neither gate is removed or pulled into M0 by this document.

## 2. Frozen upstream references

### Zed workflow reference

Selected release: **Zed v1.27.0**, published **2026-11-04T17:04:23Z**, non-prerelease. GitHub's latest-release endpoint returned this release on the research date; the acceptance target is the explicit pin, not a perpetually moving “latest.”

- [Release](https://github.com/zed-industries/zed/releases/tag/v1.27.0)
- [Release API](https://api.github.com/repos/zed-industries/zed/releases/tags/v1.27.0)
- [Resolved commit](https://github.com/zed-industries/zed/commit/c84af5b99cbc366d675064e52b23664a015b6e35): `c84af5b99cbc366d675064e52b23664a015b6e35`
- [Tag-to-commit API](https://api.github.com/repos/zed-industries/zed/commits/v1.27.0)

All Zed source links below use that commit. SHA-256 values hash the raw UTF-8 file bytes, not Git blob IDs or rendered pages. For raw retrieval replace `github.com/.../blob/` with `raw.githubusercontent.com/.../`.

| ID | Exact reviewed source URL | SHA-256 |
| --- | --- | --- |
| Z-GIT | [docs/src/git.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/git.md) | `ad4710e0b2c44a36243a2daa9aea1dceb6bdaff2d97dc125f33bfc57dbf33389` |
| Z-EXCERPT | [docs/src/multibuffers.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/multibuffers.md) | `d4914198207aa65019bc7b3dfc96031f7a2a9cc415849bd8949efeff2ff0778c` |
| Z-AGENT | [docs/src/ai/agent-panel.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/ai/agent-panel.md) | `a85659c22701969e504a30c9f05c9359b40fad0643649e0fd073aa3ce4e69789` |
| Z-ACP | [docs/src/ai/external-agents.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/ai/external-agents.md) | `af9a2f0be91ed0c9c0ea169dece9596b7e8cab728f1e24470ee1ad57b32b9ee1` |
| Z-COMMAND | [docs/src/command-palette.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/command-palette.md) | `fd93436c6c1a968e10fff242edae6ce62b90aaff6977b11cbfa792ffb96fdffb` |
| Z-TERMINAL | [docs/src/terminal.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/terminal.md) | `f5af5bcbaedd1822213463ba99686b203324e5db8222490f98436757b1beecf6` |
| Z-PROJECT | [docs/src/windows-and-projects.md](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/docs/src/windows-and-projects.md) | `c2ca221235cc40322cf60c32aa60ffd1b9eff89c72389129cb238e1324da1cf5` |
| Z-KEYS | [assets/keymaps/default-linux.json](https://github.com/zed-industries/zed/blob/c84af5b99cbc366d675064e52b23664a015b6e35/assets/keymaps/default-linux.json) | `5a4c557c399aa092a8db6793b090165507c6c39de71e27332c9f74ac353c7013` |

Important release-specific finding: **v1.27.0 removed agent checkpoints and Restore Checkpoint**, citing performance problems in large repositories. Do not claim Coral's proposed checkpoints/recovery journal reproduce this release's checkpoint UI. Keep Coral's recovery safety requirement as a deliberate product choice.

### ZLS reference (future M3 integration)

- Installed observation: `/usr/bin/zls --version` → `0.17.0`.
- [Release 0.17.0](https://github.com/zigtools/zls/releases/tag/0.17.0), published 2026-10-19T23:00:55Z.
- [Resolved source commit](https://github.com/zigtools/zls/commit/542462c4ddf045493fa9ca028ee6bc3f38b2754a): `542462c4ddf045493fa9ca028ee6bc3f38b2754a`.
- [Tag-to-commit API](https://api.github.com/repos/zigtools/zls/commits/0.17.0).

The source pin identifies the upstream version reference; the local executable was not compared with upstream release assets. M3 must still test initialize/capability negotiation, Unicode position conversion, definitions, completion, rename, formatting and crash/restart with this installed version, recording the actual executable/toolchain. Merely finding ZLS does not close those gates.

### ACP target (future M7, not an integration claim)

Select **stable v1 schema release `schema-v1.29.1`**, published 2026-11-02T10:51:47Z, at commit **`0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b`**.

- [Release](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.29.1)
- [Resolved commit](https://github.com/agentclientprotocol/agent-client-protocol/commit/0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b)
- [Tag-to-commit API](https://api.github.com/repos/agentclientprotocol/agent-client-protocol/commits/schema-v1.29.1)
- [Stable schema release asset](https://github.com/agentclientprotocol/agent-client-protocol/releases/download/schema-v1.29.1/schema.json)

| Exact source URL | SHA-256 |
| --- | --- |
| [schema/v1/schema.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b/schema/v1/schema.json) | `0d0b1ca83c4872e5473f68926a894c7a8203b59b118e2a79bfe43dd76fbcbc1a` |
| [schema/v1/meta.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b/schema/v1/meta.json) | `061edb6efa8fb2aa2792459a86ec7268de5fe665bba48b2ffe7939df01481f88` |
| [schema/v1/Cargo.toml](https://github.com/agentclientprotocol/agent-client-protocol/blob/0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b/schema/v1/Cargo.toml) | `23cdfaf3b374ee63b0c5b5efc171ca31c2a9a4bd9b308db6f5fc5054e7b7766b` |
| [docs/protocol/v1/initialization.mdx](https://github.com/agentclientprotocol/agent-client-protocol/blob/0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b/docs/protocol/v1/initialization.mdx) | `531e20a108164c7f00dc992b86e7b893bbfcda6eadc6dc4d7d156d01de70d6ea` |

The stable schema is 256,258 bytes, uses JSON Schema draft 2020-12, and its computed hash matches the release API's advertised asset digest. The asset itself was not separately downloaded. The manifest says schema package **1.29.1**; metadata and initialization specify wire **`protocolVersion: 1`**. These are different version namespaces: do not send `1.29.1` as `protocolVersion`. Do not silently select `schema/v2`, `schema.unstable.json`, or draft features present in the same repository.

M7 acceptance must negotiate the supported integer version, reject unsupported versions, treat omitted capabilities as unsupported, and advertise only implemented features. Test session new/prompt/update/cancel, permission allow/deny/cancel, bounded malformed/fragmented input, unsupported filesystem/terminal callbacks, disconnects and late responses using local fake peers first. Then pin at least two actual adapters and publish their auth/resume/model/MCP/terminal capability differences. No particular adapter version is selected or claimed tested here. Native Coral profiles and credentials must not be presented as automatically controlling external agents; ACP is not OS confinement.

## 3. Finite workflow acceptance selection

This selection freezes concrete stories for M0 design review and later executable fixtures; it does not replace or shrink the full capability matrix in the plan. **All execution results in the table are pending in this research task.** “Source-reviewed” means the referenced documentation/keymap was inspected, not that Zed or Coral passed the story.

Use disposable fixtures: two distinct roots with colliding basenames, two small Unicode text documents, a temporary repository with two separated edits in one file, and deterministic agent/protocol replies. Record fixture bytes/hashes and expected before/after snapshots when making the stories executable. Never exercise commit, discard, crash or process tests against the developer checkout.

| ID / delivery gate | Selected actions and acceptance oracle | Reference / intentional boundary |
| --- | --- | --- |
| W01 — M1 | Open palette from editor and Find input; filter New document; Enter dispatches once. Escape restores the prior live input without mutation. Disabled/unimplemented services are not offered as working commands. | Z-COMMAND, Z-KEYS; focus restoration is a Coral safety requirement. |
| W02 — M0 spike, M1 native | Show the same canonical document in two visible panes, select different ranges (including a reversed selection), scroll independently, type in one, then undo from the other. Both show identical document text but retain independent visible selections and scroll. Close either pane without losing the remaining document or callbacks. | Z-PROJECT/Z-KEYS establish split/layout reference; precise simultaneous selection/lifetime invariants are Coral acceptance, not a claim of a Zed runtime test. |
| W03 — M0 spike, M4 full Git UI | Show two editable excerpts from different source documents plus a read-only old side. Edit a current excerpt; only its mapped source changes and other views update. One undo restores the source edit. Headers and historical text cannot be edited. | Z-EXCERPT and Z-GIT; detailed mapping tests below. Full staging/navigation UI remains M4. |
| W04 — M1 | New → edit → Save As; canonical-path reopen deduplicates. Opening a missing file/FIFO creates nothing. An edit during save stays dirty; cancellation/failure preserves the original and current edits. | Existing Coral integrity contract, not an assertion that Zed has identical open-path behavior. |
| W05 — M1 | Prepare a two-document transaction, modify one target (including edit then undo), then commit the old transaction: reject all targets without partial buffer mutation. For a valid transaction preserve undo grouping and attributable changes. | Coral transaction/recovery requirements; do not equate validation atomicity with atomic filesystem writes. |
| W06 — M1 | Interrupt recovery publication/save at controlled points, restart in isolated XDG state, and recover dirty/untitled text through a chooser. If disk changed, show a conflict rather than overwrite it. Corrupt/truncated/newer-version recovery records fail safely. | Coral requirement; independent of Zed agent checkpoints. Exact acknowledged recovery boundary must be recorded. |
| W07 — M2 | Add two roots with the same basename file; quick-open/search retain root identity. Switch projects and return: correct tabs, dirty buffers and layout return; an outstanding operation keeps its original target. | Z-PROJECT; no inference that Coral must adopt Zed's default single-window project opening. |
| W08 — M4 | Stage one of two separated hunks, inspect HEAD→index and index→working state, unstage/re-stage it, commit staged only. HEAD equals the reviewed index, second hunk stays unstaged, unsaved buffer bytes remain unchanged. Empty index never stages tracked files implicitly. | Z-GIT, **D1** below. External index changes invalidate the prepared hunk operation. |
| W09 — M0 UX review, M6 native | Attach explicit selection/context, request an edit, inspect proposal, reject with no effect; repeat and accept one hunk. Acceptance edits the buffer only, never save/stage/commit/push. | Z-AGENT review/context workflow, **D2** below. M0 uses deterministic mock responses. |
| W10 — M0 UX review, M6 native | Deny or cancel permission; no mutation/execution follows. Cancel streaming; keep partial results inspectable. Change the target before accepting a proposal; stale acceptance is blocked even after undo to identical bytes. Switch thread/project; target does not change. | Z-AGENT/Z-ACP plus Coral revision/permission requirements. No live provider prerequisite for design review. |
| W11 — M0 terminal spike, M5 complete | Embed a real local PTY-backed terminal candidate; display Unicode, type/resize, observe child exit, cancel and close. Verify reaping/ownership and that output cannot dispatch workbench commands. | Z-TERMINAL; canned prototype commands and bounded stdout capture alone do not establish terminal feasibility. |
| W12 — M7 | Local ACP fake peer negotiates v1, omits optional capabilities, requests permission, streams updates and cancels; UI hides unsupported controls and handles disconnect without side effects. Later repeat supported cases with two pinned real adapters. | Z-ACP and pinned ACP initialization/schema; no integration claimed now. |

### Linux keybinding reference subset

These entries were read from **Z-KEYS**, with their declared contexts. This is a source-level preset fixture, not a claim that Coral implements a Zed preset today. Context priority, user overrides, terminal keys and IME handling still require executable tests. Coral's normal keymap may differ.

| Context | Upstream key | Upstream action |
| --- | --- | --- |
| `Workspace` | `ctrl-shift-p` or `f1` | `command_palette::Toggle` |
| `Workspace` | `ctrl-p` | `file_finder::Toggle` |
| `Workspace` | `ctrl-s` | `workspace::Save` |
| `Editor` | `ctrl-\` | `pane::SplitRight` |
| `Pane` | `ctrl-k down` / `ctrl-k right` | `pane::SplitDown` / `pane::SplitRight` |
| `GitPanel` | `ctrl-g d` | `git::Diff` |
| `GitPanel` | `ctrl-enter` | `git::Commit` |
| `AgentPanel` | `ctrl-n` | `agent::NewThread` |
| `AcpThread > Editor` | `ctrl-shift-r` | `agent::OpenAgentDiff` |
| `Workspace` | Ctrl + backtick | `terminal_panel::Toggle` |

### Intentional differences requiring product signoff

- **D1 — Commit staged only.** Z-GIT's “Using the Git Panel” describes automatically staging tracked files before committing. Coral's default operates only on the reviewed index; an empty index is not consent to stage. An optional future “Stage tracked and commit” is separately named and authorized. Test both a partially staged file and an empty index. Do not collapse the documented panel convenience and staged commit paths into a universal claim about every Zed commit.
- **D2 — Proposal before apply.** Z-AGENT describes reviewing changes after the agent has made them. Coral's default native-agent proposal is inert until acceptance. Reject is no-op before application; accept requires current revisions and changes buffers only. A separately approved live-edit mode needs overlap-safe rejection and recovery before being offered. External agent processes need their own containment/disclosure; the proposal policy cannot pretend to constrain arbitrary filesystem writes by an unconstrained process.
- **D3 — Recovery is Coral-owned.** Keep crash recovery and checked, attributable undo even though the pinned Zed release removed agent checkpoints. Do not promise a Restore Checkpoint button as v1.27.0 parity or implement whole-workspace rollback over later user edits.
- **D4 — Native implementation and scope.** GTK/Pearl appearance, Coral keymap defaults, explicit missing-file creation, trust policy and provider ownership are Coral choices. No GPUI rewrite, hosted Zed subscription reuse, remote workspace/collaboration/notebook support, or VS Code extension-host compatibility is implied. These exclusions do not excuse missing M0/M1 native gates.

Approval state: **not recorded here**. Source selection and scenario definition are complete research outputs; product approval, executable fixture coverage and native acceptance are separate evidence.

## 4. Editor engine decision and delegated validation

**Decision for the implementation handoff: retain GTK4 + GtkSourceView, with one canonical document and independent presentation buffers per visible editor view.** New orchestration/mapping remains Zig. Implementation is delegated; this document does not assert that the delegated code exists, passes tests or meets budgets.

Reason: GTK's insertion and selection-bound marks belong to a `GtkTextBuffer`. The reviewed [GtkTextBuffer.get_insert API](https://docs.gtk.org/gtk4/method.TextBuffer.get_insert.html) returns the buffer-owned `insert` mark. That API page is supporting, unpinned documentation, not a frozen Zed source. At the inspected local baseline, `EditorView.create` passes `document.buffer` to `gtk_source_view_new_with_buffer`; its comments explicitly warn that inactive panes may display the active pane's selection. Saving extra marks is useful but does not demonstrate independent simultaneous rendering.

Required adapter contracts:

1. The registry's canonical document alone owns authoritative text, revision, disk/format metadata, dirty state, save snapshots, recovery and undo identity. Presentation buffers are projections, never additional file owners.
2. Each view owns native insertion/selection marks, scrolling, focus and composition state in its own presentation buffer. Route typing, paste, deletion, replace, undo and redo through checked canonical operations; reconcile all presentations from the accepted revision. Prevent echo/reentrant feedback and duplicate revision/undo entries. On rejection restore the affected presentation without changing canonical text.
3. Mirror canonical changes incrementally, preserving unaffected anchors/selection direction and scroll. Disable or route presentation-local undo; never allow parallel divergent undo histories. Search/spelling/decorations must map to the owning view without treating tags as file edits. Explicitly test IME composition and clipboard paths, not just direct API insertion.
4. Full-document views and excerpt views use the same identity/revision checks. A full-document mirror must not require guessing source offsets from displayed text. Measure memory duplication and projection work before generalizing to 100 tabs.
5. Retain the native engine only on measured acceptance. If the strategy fails, record the specific correctness/performance failure and cost alternatives in a separate decision; do not silently replace the engine or relabel saved selections as independent panes.

### Excerpt mapping contract (proposed)

Each displayed editable range maps to `(DocumentId, expected revision, source anchors, excerpt identity, baseline kind)`. Source anchors have explicit insertion gravity; display-only headings/separators and historical sides map to no writable source. Coordinate conversions distinguish UTF-8 bytes, GTK character offsets and display rows; never use a displayed line number as a source byte offset. Maintain the original file's BOM/newline metadata separately.

Translate an edit wholly within one writable excerpt into a checked source transaction. Reject edits crossing headers, historical text, hidden gaps or ambiguous boundaries before any mutation. Independently mapped multi-cursor edits may become a validated multi-target transaction; cross-boundary text selection is not automatically permission to concatenate files. After an external source change, rebase through valid anchors or invalidate/rebuild the projection; never apply stale offsets optimistically. Keep Git HEAD/index baselines distinct from agent-review snapshots. Saving targets canonical documents, never the concatenated presentation text.

Proposed tests for the delegated owner; **not run or validated by this researcher**:

| ID | Required assertion |
| --- | --- |
| E01 | Two simultaneously visible full views have distinct rendered selections, including reversed selections, and independent scroll/focus; typing in either updates both texts exactly once. |
| E02 | Insert/delete/paste/IME commit route through canonical revisions; undo/redo from either view affects canonical history once and preserves other view state. |
| E03 | Edit a middle excerpt from document A and an excerpt from B; only mapped ranges change, full source views update, headers/old sides remain unchanged. |
| E04 | Reject boundary-crossing deletes/paste and writes to historical text with no change to any target or undo history; define insertion at start/end anchors explicitly. |
| E05 | Cover emoji, combining marks, non-ASCII characters, tabs, CRLF/BOM files and missing final newline. Check exact canonical bytes/format metadata after edit, save and undo. |
| E06 | Insert before/inside/after an excerpt, including exactly at each anchor; source anchors shift predictably or the projection invalidates. A stale prepared edit, including edit-undo ABA, cannot land in the wrong range. |
| E07 | Multiple/overlapping excerpts of one source reflect one accepted change consistently; duplicate mapped edits are rejected or normalized explicitly, never applied twice. |
| E08 | A rejected multi-document transaction leaves every source and presentation unchanged. Successful logical multi-file undo/recovery records per-file outcomes and never overwrites newer user edits. |
| E09 | Close a view/document or change Save As identity while updates are queued; stale callbacks cannot access freed state or retarget another document. |
| E10 | Save from an excerpt writes only the intended canonical document(s), preserving text outside the excerpt. Projection refresh creates no dirty state, extra save, staging or commit. |

M0 requires a native two-view demonstration and at least one editable diff excerpt with source synchronization and undo. M1 requires integrated independent groups/views, safe edit paths and recovery, not only an isolated widget spike. E01–E10 identify the implementation/testing handoff, not completed milestones.

## 5. Minimal M0 benchmark methodology and gates

**Runner owner: parent implementation task**, as delegated. This research creates no runner and reports no performance measurements. Use a bounded Zig runner/instrumentation where practical, with Python permitted for test orchestration. Keep generated data in private fixture/output directories, not the developer's documents. Do not add a benchmark command to documentation as executable until the runner actually provides it.

### Measurement rules

- Record source revision plus dirty diff identity, executable SHA-256, exact build command/optimization, Zig/GTK/GtkSourceView versions, CPU/RAM/storage, kernel, GPU/renderer, compositor, display refresh/scale, window dimensions/font/theme, power mode and fixture hashes. Pin the reference machine in the first baseline report.
- Test an isolated XDG/private native session, no live provider/network latency, and no unrelated background services. Record syntax/spelling/wrap/reduced-feature settings; use normal editing features for the primary run. Report stripped-down variants separately, never substitute them silently.
- Startup clock: immediately before process launch to first presented, focused, input-ready editor frame. A mapped window or completed buffer load alone is not readiness. Separate first-process/cache-unspecified launches from warm relaunches. Do not claim cold-cache measurements without documenting the cache-control method; do not drop system caches on the user's live session.
- Input clock: injected event timestamp to the frame presenting the expected text, including canonical update and presentation synchronization. Record main-loop stalls separately. If the harness only observes a frame callback rather than compositor presentation, label the metric accurately; a callback or buffer-change timing is not verified keystroke-to-paint.
- At least 20 measured launches per reported startup class; 1,000 input samples per editor workload after an explicitly excluded warm-up; report sample count, nearest-rank p50/p95/p99, maximum, failures and raw samples. Run each tab/excerpt workload at least five times. Bound each trial with a watchdog; timeouts are failures, not dropped samples.
- Sample RSS/peak RSS and document/view counts at idle baseline, after opening/settling, after editing and after close/reopen cycles. Hash outputs and verify undo/save invariants alongside speed. Fail on data corruption, stale application, crash or hang regardless of timings.

### Required workload matrix

Only the 1 MiB input numbers below are already numeric plan targets. Other thresholds are **proposed M0 screening budgets**, not upstream Zed claims, measured results or silently approved amendments to the plan. The parent/product reviewer must accept or explicitly revise them with evidence before closing M0. A failed budget needs a recorded corrective decision and rerun, not a hidden exemption.

| ID | Deterministic workload and metric | Gate |
| --- | --- | --- |
| B01 — startup | Empty editor and opening one 1 MiB file; first-process/cache-unspecified and warm launches separately; time to input-ready presentation. | Proposed p95 ≤ 2 s first-process and ≤ 1 s warm on recorded reference hardware. Always record distributions and peak RSS; verified cold-cache measurements are a separate class if available. |
| B02 — 1 MiB input | Exactly 1,048,576 UTF-8 bytes of deterministic source-like lines; edit near beginning/middle/end, type/delete/undo, then repeat with two visible presentations. Include Unicode test locations. | Plan target: keystroke-to-paint p95 ≤ 16 ms, p99 ≤ 32 ms. No text loss or divergent view. If the runner cannot measure paint, this target remains unverified, not passed by a proxy. |
| B03 — large line | Exactly 1 MiB without LF; insert/delete/undo near start/middle/end, move caret and horizontal scroll. Test wrapping off and on, reported separately. Also record the existing >10 MiB reduced-feature boundary. | Proposed editing p95 ≤ 50 ms, p99 ≤ 100 ms, no attributable main-loop stall > 100 ms during steady editing. Bound load/layout trial to 10 s. A fallback must be visible and approved; no unannounced disabling of editing. |
| B04 — 1/20/100 tabs | Distinct 64 KiB documents with deterministic contents; open 1, 20, then 100 tabs, cycle active tabs, edit/undo, close to baseline and repeat five times. Separately measure a second view of one document. | Proposed switch-to-visible p95 ≤ 100 ms and ordinary input p95 ≤ 16 ms / p99 ≤ 32 ms. Report total/per-document/per-view RSS, not only ratios. After first-cycle allocator warm-up, settled post-close RSS across later cycles must not grow monotonically beyond max(10 MiB, 5% of warmed baseline). Investigate retained objects before calling allocator retention a leak. |
| B05 — excerpts | Ten 64 KiB source documents, ten 20-line excerpts per document (100 total), read-only historical text and headers, one additional full-source view. Edit first/middle/last excerpt, refresh after source edit, undo. Record construct/refresh and event-to-visible latency. | Proposed initial projection ≤ 250 ms, edit p95 ≤ 16 ms / p99 ≤ 32 ms, no main-loop task > 50 ms attributable to projection refresh. E03–E10 correctness is mandatory even if timing passes. |

The runner must publish exact fixture generation rules and hashes (including newline/wrap settings), not just labels such as “large file.” B01–B05 are minimum M0 engine baselines, not the entire performance qualification. The plan also retains 10 MiB reduced-feature behavior, the 128 MiB load cap/rejection, diagnostics floods, concurrent diffs, idle soak and later 100k-file/search/Git/protocol budgets. Preserve existing size-limit regression coverage during M1; later service benchmarks stay with their milestones.

## 6. M0/M1 completion audit and assignment gaps

Audit sources: [plan §4](WORKBENCH_IMPLEMENTATION_PLAN.md#early-gtksourceview-feasibility-gates), [plan §10](WORKBENCH_IMPLEMENTATION_PLAN.md#10-delivery-sequence-and-gates), [initial batch](WORKBENCH_IMPLEMENTATION_PLAN.md#initial-implementation-batch-and-remaining-gates), [validation](WORKBENCH_IMPLEMENTATION_PLAN.md#11-validation-and-release-acceptance), and [reported open gates](WORKBENCH_STATUS.md#milestone-gates-still-open).

“Unassigned” below means **no owner confirmed in this research brief or inspected plan/status**, not proof that no parallel task exists. Parent must reconcile actual assignments. Do not silently move an M0/M1 obligation to a later milestone merely because the first batch did not name it.

| Required gate | Evidence / handoff | Ownership or missing assignment |
| --- | --- | --- |
| M0 parity/reference pin; initial batch 1 | Zed/ZLS/ACP pins, finite scenarios and differences recorded here. | Research delivered; executable user-story/keymap fixtures and explicit matrix/difference approval still need an owner. This Markdown is not an executable test fixture. |
| M0 independent view/excerpt feasibility; batch 5 | Canonical document + independent presentation-buffer decision and E01–E10 specified. | Implementation delegated per brief; implementing owner must supply native evidence. No success inferred here. |
| M0 benchmarks | B01–B05 methodology and proposed budgets recorded. | Parent owns runner, measurement and budget disposition. |
| **M0 terminal feasibility** | Explicit in milestone scope and §9; stdout capture is not a PTY/widget spike. Must compare GTK4 VTE versus suitable existing infrastructure for embedding, maintenance/license boundary, resize/Unicode/exit and ownership. | **Missing confirmed assignment.** Assign a terminal-spike owner or keep M0 open; full tasks/terminal UI remains M5. |
| **M0 UX/prototype review and approval** | Existing prototype guide describes keyboard, permission, staging, stale-edit and narrow/dark/light scenarios and historical browser results. W08–W10/D1–D2 give review targets. Browser fixtures cannot prove native splits/performance. | **Missing confirmed reviewer/signoff.** Review the actual prototype/artifacts and intentional differences; this source review is not product UX approval. |
| §4 extra engine risks | Multi-cursor, overlays/inlay hints, folding and inline suggestions are named early feasibility risks alongside huge lines. Independent presentation buffers alone prove none of these. | **No confirmed spike owner/evidence.** Parent must record feasibility disposition before promising them; full advanced-editing delivery stays M8. |
| M1 regression preservation; batch 2 | Status reports earlier path/save-race, spelling/theme and integrity passes. | Fresh build/unit/widget/native regression owner/result needed after integration. Historical passes do not qualify new view/recovery changes. |
| M1 registry/view/group separation; batch 3 | Existing registry/view extraction is reported, but shared visible marks and single group are the inspected baseline. | Delegated editor work must include usable native independent groups/views, callback lifetime and single-file compatibility—not just saved marks. |
| M1 stale/multi-file edit safety; batch 4 | Existing checked transactions are reported; W05/E08 require integrated presentation synchronization and recovery-aware logical grouping. | Confirm transaction/recovery integration owner. Per-buffer undo is not a completed workspace-wide recovery strategy. |
| **M1 interrupted saves and recovery** | W06 requires versioned journal/snapshots, safe publication, chooser, corruption/conflict handling, crash injection and per-file outcomes for partial saves. Ordinary M2 workspace restoration is not a substitute. | **No confirmed owner in this brief.** Assign explicitly before M1 signoff. Document the recovery durability boundary; do not claim globally atomic disk writes. |
| M1 file watchers | Existing external-change detection/reload tests are reported. | Revalidate across multiple presentations, Save As, close and recovery; record disk-conflict behavior. Integration owner must be confirmed. |
| **Initial batch 6: workspace IDs** | Plan explicitly requires workspace identity before service expansion; status says it is not implemented. A full explorer is not required for identity routing. | **Missing confirmed assignment.** Supply IDs and late-result isolation tests without claiming M2 is complete. |
| **Initial batch 6 / M1 lifecycle: supervised processes** | Reported capture API kills/reaps only the direct child; status leaves process-tree lifecycle open. Need bounded cancellation/escalation, owned descendants, close/shutdown reaping and isolation from stale callbacks. | **Missing confirmed assignment.** Tie to terminal spike as appropriate; capture tests alone do not close this gate. |
| Initial batch 7: integrated evidence review | Aggregate native correctness, recovery, benchmarks, UX decision and remaining limitations. | Parent owns final integration/signoff; explicitly assign any still-unowned work above. |

The initial seven-item batch is narrower than the full milestones: it omits an explicit terminal task, benchmark task, recovery task and UX approval task, even though those appear in M0/M1 scope/exit or supporting contracts. The benchmark and editor delegates cover only part of that gap. **Completing this research document plus those delegates is not by itself completion of M0/M1.**

### Required final evidence package (parent-owned)

1. Approved matrix and D1–D4 disposition; finite stories mapped to executable fixture/test IDs, with future M2–M7 cases clearly separated from current gates.
2. Native two-pane and editable-excerpt evidence tied to the integrated source revision, showing real input, independent rendering, canonical undo and negative mapping cases.
3. Terminal feasibility decision/evidence and explicit disposition of other §4 engine risks.
4. Reproducible B01–B05 raw results, fixture/environment hashes, budget decisions and no unexplained skipped workload.
5. Fresh M1 regressions plus crash/recovery/multi-file/process lifecycle fault tests; explicit durability, filesystem atomicity and undo limitations.
6. Actual prototype/UX review outcome and an integrated M0/M1 acceptance review. Any unmet gate remains open rather than being called a completed foundation milestone.

No plan/status/mockup/production files are changed by this research. Future implementation evidence belongs in the parent task's authorized outputs; this document must not be used as evidence that those tests have already passed.

## 7. Local source provenance

Inspected baseline HEAD: `dee722fe018c5db3d864ad905c9f9157f794b4fe` in `pearl`. Paths below are relative to Coral. These hashes identify the reviewed baseline, not a promise that concurrently delegated work leaves it unchanged.

| Local source | SHA-256 at inspection |
| --- | --- |
| `docs/WORKBENCH_IMPLEMENTATION_PLAN.md` | `d515d919a268c089ca17f10e2e4b28f6f308905fcb5123f52425fdd905953983` |
| `docs/WORKBENCH_STATUS.md` | `0f64180f053913d7f131bcf5cadbf9930dbce7d7553465ea629d51139fac7b04` |
| `src/editor/view.zig` | `791538cbd0873ada9d69550ed4821bf5b1b951c5161a1a748a5d3a465669f1ab` |
| `docs/mockups/workbench/README.md` | `68edb969c9a9ad8d6ef3d134d67ac67579bfafc050feb048d16ae777d7c45e13` |

The prototype guide's reported 32 browser checks/52 geometry checkpoints and the workbench status's reported unit/widget/native passes were read, not rerun. The full Zed binary was not executed. No commit was created.
