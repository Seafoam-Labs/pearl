# Workbench M0 — executable prototype fixtures and technical UX review

Review date: **2026-11-08**. Reviewer: **coding agent, technical review**, not a user study or product approver.

## Disposition and authority

**The requested offline prototype execution and technical artifact review are complete. User approval is not recorded.** The final expanded browser run passed **40/40** cases, with **55 geometry checkpoints**, **23 screenshots**, and no observed external requests, console errors, or uncaught page errors. This is not an M0/M1 completion declaration.

This document joins the frozen **W01–W12 / D1–D4** definitions in [WORKBENCH_M0_REFERENCES.md](WORKBENCH_M0_REFERENCES.md#3-finite-workflow-acceptance-selection) to executable fixtures without changing that reference document. Its original research-only/pending statements remain historical; use the execution evidence here for this review. A passing related browser fixture does **not** mean the entire reference story passed.

- **Delivered here:** refreshed browser evidence, eight additional executable cases, exact fixture snapshot receipts, workflow mapping, actual screenshot/usability inspection, and a small prototype-only picker-availability fix.
- **Still open:** explicit user/product approval of the workflow matrix and D1–D4; separate native M0/M1 gates and their integrated acceptance. Native test sources referenced below were inspected/located, **not executed by this reviewer**.
- **Later native M2+ features are not implemented by this work:** real workspace persistence/services, LSP, Git, terminal/task UI, providers, ACP and advanced editing remain their respective native milestones. A browser simulation is not their implementation. In particular the M0 terminal feasibility spike remains a current, separate obligation; it must not be deferred just because full terminal UI belongs to M5.
- **Ownership respected:** only `docs/mockups/workbench/**`, new `tests/prototype_m0.py`, and this document were changed. No `src`, application, main, build, reference, plan, or status edits; no commits. Concurrent native work is not credited as this review's result.

## Reproduce and inspect the evidence

Read [the prototype interaction/test guide](mockups/workbench/README.md) first. The existing browser harness is [verify.py](mockups/workbench/verify.py); the new [tests/prototype_m0.py](../tests/prototype_m0.py) imports it rather than creating a second browser driver. Both execute real keyboard, click and input events; internal state reads are read-only. The only clock manipulation is Playwright's deterministic timer control.

Commands actually run, **from the `pearl` root** using the already-installed validation environment:

```sh
# Original suite, rerun before and after the prototype fix.
PLAYWRIGHT_BROWSERS_PATH=/home/zoey/Projects/pearl/.cache/coral-workbench-validation/browsers .cache/coral-workbench-validation/venv/bin/python -B subprojects/coral/docs/mockups/workbench/verify.py

# New cases during development; explicitly produces a partial report.
PLAYWRIGHT_BROWSERS_PATH=/home/zoey/Projects/pearl/.cache/coral-workbench-validation/browsers .cache/coral-workbench-validation/venv/bin/python -B subprojects/coral/tests/prototype_m0.py --only 'M0 '

# Final complete suite: all 32 original cases plus 8 new cases.
PLAYWRIGHT_BROWSERS_PATH=/home/zoey/Projects/pearl/.cache/coral-workbench-validation/browsers .cache/coral-workbench-validation/venv/bin/python -B subprojects/coral/tests/prototype_m0.py

node --check subprojects/coral/docs/mockups/workbench/mockup.js
```

| Run | Actual result | Evidence |
| --- | --- | --- |
| Original baseline | 32/32 passed before changes | Terminal run; superseded by the post-fix original-suite report below |
| New cases during development | First 5/8: test selectors incorrectly counted unrelated model/profile `<option>` elements; scoped selectors to picker. Next **7/8**, reproducing the unavailable-command defect | [Preserved pre-fix partial report](mockups/workbench/m0-pre-fix-verification.json), [failure capture](mockups/workbench/failure-m0-w01-unavailable-fixture-commands-are-not-offered-as-working.png) |
| Final expanded run, start `2026-11-08T22:15:00.373319+00:00` | **40 passed, 0 failed; 29.887 s; full run**. 55 geometry checkpoints; 23 screenshots; 14 fixture receipts | [m0-review-verification.json](mockups/workbench/m0-review-verification.json) |
| Original suite after fix, start `2026-11-08T22:15:48.991012+00:00` | **32 passed, 0 failed; 25.513 s; full run**. 52 geometry checkpoints | [verification.json](mockups/workbench/verification.json) |
| JavaScript syntax | Exit 0 | `node --check` command above |

Both final browser runs: **Chromium 156.0.8078.4**, headless, Playwright-supplied Ubuntu fallback browser on `Linux-7.3.3-1.1-devario-llm-x86_64-with-glibc2.44`. No dependency installation, server, real repository mutation, provider request or credentials were needed. Each isolated context is offline, aborts non-`file:` requests and asserts the exact three local assets loaded. Both reports record **0 external requests, 0 console errors, 0 page errors**.

The expanded report includes:

- `source_sha256` for HTML/CSS/JavaScript and the reused harness; `additional_source_sha256` for the new runner and reference document. Tested `mockup.js`: `a0e78c083db7ea8105696faa17c38cebaec0042f94574b75989d910a4f273094`.
- `workflow_mapping`: all 12 workflow IDs and four difference IDs; exact browser case names, explicit limits and native source links. Missing IDs, unknown mapped browser functions or missing linked native files fail runner setup rather than silently producing a coverage claim.
- `fixture_receipts`: exact JSON strings for HEAD/index/buffer/preview-save, revisions, tabs, roots and simulated commits for **both** workspaces. Each receipt has a SHA-256 of its UTF-8, `ensure_ascii=False`, sorted-key JSON serialization. These are disposable page fixtures, not checkout files. Source hashes freeze the fixture-generation rules.
- Before/after equality assertions: empty index never stages or commits; approval and proposal leave every document/commit unchanged; rejection changes nothing; acceptance changes exactly the target buffer/revision; undo restores bytes but not revision validity; reload resets all fixture state. The existing partial-hunk case independently asserts HEAD equals the reviewed index while the other hunk and preview-save remain unchanged.
- `linked_native_sources_not_executed_sha256`: provenance for native handoff references only, **not native pass results**. These files may change in parallel; fresh native validation belongs to their owners.

Focused runs overwrite `m0-review-verification.json` with `partial_run: true`; rerun the complete command before citing a full result. The original runner writes only `verification.json`. Both runners refresh shared baseline screenshots. The intentionally failing historical report remains separate and must not be mistaken for the final result.

## W01–W12 executable fixture map

Function names below identify runnable cases in [existing `verify.py`](mockups/workbench/verify.py) or [new `prototype_m0.py`](../tests/prototype_m0.py). The JSON expands them to the human-readable names printed by the runner. **“Partial” and “negative boundary” are not full-story acceptance.** No native test linked here was run in this review.

| ID / gate | Executable evidence and actual result | Boundary / remaining acceptance |
| --- | --- | --- |
| **W01 — M1** | Browser `quick_open_keyboard`, `command_palette`, `m0_palette_contexts`, `m0_command_availability` **passed**: shortcuts, nested picker, arrow/Enter, empty result, Escape back to editor/workspace search, theme dispatch, unavailable fixture actions hidden. Native [tests/native.py](../tests/native.py) has New document and Find/Replace focus cases. | **Partial.** Browser has no New document or native Find input. Native New/Find/exact-dispatch/keymap-context gate not rerun; not Zed preset parity. |
| **W02 — M0/M1** | No browser equivalent. Existing native [tests/app_groups.py](../tests/app_groups.py) and [view_test.zig](../src/editor/view_test.zig) are concrete executable handoff fixtures for shared documents, directed selections and view lifetime. | **Not implemented in prototype.** Simultaneous independent panes, scroll, opposite-pane undo and callback lifetime need native evidence; tab switching is not a substitute. |
| **W03 — M0/M4** | No browser equivalent. Native [excerpt_tests.zig](../src/editor/excerpt_tests.zig), [excerpt_editor_tests.zig](../src/editor/excerpt_editor_tests.zig), [app_groups.py](../tests/app_groups.py) cover mapped edits/history, Unicode, stale sources and read-only displays. | **Not implemented in prototype.** Read-only Git display is not an editable multibuffer/excerpt widget. M0 native mapping evidence and later M4 UI remain separate. |
| **W04 — M1** | Browser `tabs` **passed** for typing, close/reopen and preview save. Native [tests/native.py](../tests/native.py) contains filesystem/path/save regressions, including missing paths/FIFOs. | **Partial analogy only.** No browser Save As, canonical-path deduplication, filesystem writes or save races. Native acceptance remains separate. |
| **W05 — M1** | Browser `m0_stale_undo` **passed**. Native [history_tests.zig](../src/editor/history_tests.zig), notably `history pending stale commit and no-op do not discard redo; bounded eviction` and `history overlapping newer edits and edit native undo refuse ALL buffers`, are executable transaction/history handoffs. | **Partial analogy only.** A one-buffer proposal is not an all-target transaction or attributable grouped workspace undo. |
| **W06 — M1** | Browser `m0_reload_boundary` **passed** as an explicit negative boundary; saved-preview text and simulated commits reset on reload. Native [tests/app_recovery.py](../tests/app_recovery.py) is the actual isolated-session crash/recovery harness. | **No recovery implementation in prototype.** Publication failure, conflicts, corruption/version safety and recovery chooser need native results; do not transfer the browser pass to W06 acceptance. |
| **W07 — M2** | `workspaces`, `m0_root_identity`, `agent_workspace_target` **passed**: add sample root, duplicate `README.md` basenames retain full root paths, `M0 café Ω 🪸` search finds/selects both roots, dirty tabs/search/index survive switching, pending work retains its original target. | **Partial M0 simulation; native M2 not implemented here.** Layout is global, not restored per workspace; fixed memory roots are not a real folder picker or durable project session. |
| **W08 — M4** | `git_file`, `git_hunk`, `m0_empty_index` **passed**: stage/unstage/re-stage one separated hunk; HEAD→index review; commit index only; other hunk stays working; unchanged unsaved bytes. Message plus empty index cannot implicitly stage/commit, including after unstage. | **Partial M0 simulation; native M4 not implemented here.** No external-index mutation or stale external-hunk oracle; no shell Git, actual repo, checkout, push, merge or multi-repository transaction. |
| **W09 — M0 UX/M6** | `agent_accept`, `agent_reject`, `m0_proposal_receipts` **passed**: Ctrl+Enter submission, no snapshot before permission, no mutation during approved read or proposal, reject no-op, accept buffer-only with all other workspace files and commits unchanged. | **Partial M0 simulation; native M6 not implemented here.** Active file is the only context; no selection attachment/context picker, no per-hunk acceptance, no live model. The one-hunk canned patch is accepted as a whole. |
| **W10 — M0 UX/M6** | `agent_deny`, `agent_cancel_approval`, `agent_cancel_read`, `agent_stale`, `agent_typing_during_read`, `agent_background_stale`, `agent_workspace_target`, `m0_stale_undo`, `m0_narrow_review` **passed**: deny/cancel, timer cancellation, focus, stale during/after read, real browser undo to identical bytes, original workspace/file/thread ownership. | **Partial M0 simulation; native M6/M7 not implemented here.** Local timer is not token streaming; no partial-stream inspection, provider process, ACP cancellation or permission confinement. |
| **W11 — M0 spike/M5** | Browser `terminal` **passed only for simulated commands**, keyboard panel navigation and unsupported-command disclosure. Located native [pty_test.zig](../src/terminal/pty_test.zig): `PTY native isatty, initial size, resize, argv, UTF8 bidirectional bytes and EOF`, cancellation/reaping, exec failure/denial. | **Negative browser boundary, not terminal feasibility.** Native PTY tests were not run here and do not alone establish an embedded GTK terminal/widget choice. M0 feasibility evidence is separately required; full native M5 not implemented here. |
| **W12 — M7** | **No executable ACP fixture in this browser suite.** Machine-readable mapping deliberately has no browser case; it reports “not implemented,” not a skipped success. Permission mockups are not protocol tests. | **Native M7 not implemented here.** Need local v1 fake peer, capability omission, streaming/cancel/disconnect and side-effect checks, then two pinned real adapters. No ACP parity/integration claim. |

## D1–D4 technical disposition versus approval

All four remain **pending explicit user/product approval**. These recommendations are review judgments, not signoff.

| Difference | Executable tie / technical disposition | Approval |
| --- | --- | --- |
| **D1 — staged-only default** | `git_hunk` + `m0_empty_index`: passed. Recommend retaining the explicit **Commit staged only** label and staged/working separation; no convenience auto-stage. Empty-index and partial-index stories are distinct checks. | **Not recorded** |
| **D2 — proposal before apply** | `m0_proposal_receipts`, denial/cancellation cases and `m0_stale_undo`: passed. Recommend inert proposal, explicit read, revision gate and buffer-only apply. Does not constrain arbitrary external-process filesystem writes. | **Not recorded** |
| **D3 — Coral-owned recovery** | `m0_reload_boundary`: negative-boundary pass. Native recovery/history fixtures are linked above but not executed. Retain native checked undo/recovery requirements; no Restore Checkpoint or whole-workspace rollback claim based on this browser prototype. | **Not recorded** |
| **D4 — native implementation/scope** | `initial`, `branch`, `terminal`, `m0_palette_contexts`, `m0_narrow_review`, `toggles` and eight responsive cases passed. Visible simulation/privacy labels are appropriate; recommend preserving them until services are real. Browser appearance is not GTK/Pearl accessibility or GPUI parity. No hosted subscription reuse, remote/collaboration/notebook support or extension host implied. | **Not recorded** |

## Actual artifact and usability review

Method: executed the above interactions through Chromium, then **opened and visually inspected the generated PNGs**, including both 1440 themes, 1024 light, 700 dark, both 390 editor themes, dark/light narrow agent review, light Explorer/deny/cancel, duplicate-name picker, partial/empty Git index and stale-after-undo. This is an agent-led technical review of real renderings, not participant feedback, physical-device use or a screen-reader audit.

| Area | Observed artifact / interaction | Judgment and remaining risk |
| --- | --- | --- |
| Desktop hierarchy and themes | [1440 dark](mockups/workbench/workbench-1440-dark.png), [1440 light](mockups/workbench/workbench-1440-light.png), [1024 light](mockups/workbench/workbench-1024-light.png). Explorer → editor → agent separation is clear; 1024 hides the agent until requested. Theme toggle retains buffers. | Suitable for further product review. Small muted helper/status text and icon-only toolbar affordances need actual accessibility/contrast and user testing; geometry passing is not a contrast pass. |
| Keyboard/palette | Escape restores live editor/search input; theme command dispatches without changing files; nested quick-open gives focus to editor. [Search focus after palette](mockups/workbench/m0-palette-search-focus.png). | No reproduced keyboard blocker after the fix below. Browser-reserved shortcuts, IME and native keymap context priority remain unqualified. |
| Workspace identity | [Duplicate README picker](mockups/workbench/m0-root-identity.png) shows full `coral/README.md` versus `shared-ui/README.md`; Unicode result selection and return to dirty tabs were asserted. | Full path is useful, but secondary path text is small. Per-workspace layout restoration is absent; do not mark full W07 complete. Composer shows only a basename, while the permission card correctly gives the full captured path; a fuller composer context is a later UX improvement. |
| Git safety | [Partial stage](mockups/workbench/git-partial-stage.png) visibly places `main.zig` in both lists and labels **Staged · HEAD → index**; [empty index](mockups/workbench/m0-empty-index.png) shows zero staged files with a disabled commit button despite a message. | The label explains what commits. The fixture intentionally allows staging the typo; this tests content ownership, not semantic code quality. Subtle disabled styling could be clearer, but the adjacent zero-staged summary and enforced guard prevent implicit staging. |
| Proposal and permissions | [Permission](mockups/workbench/m0-permission.png), [rejected](mockups/workbench/m0-rejected.png), [stale after undo](mockups/workbench/m0-stale-after-undo.png). Card gives target and buffer-only consequences; rejection/denial/cancellation remain inspectable; stale replaces Accept with Prepare new request even when text again looks saved. | Recommend keeping the explicit statuses and fresh-request action. Do not describe the canned timer as streaming or infer multiple-file/selection review from this one-file proposal. |
| Narrow drawers | [390 dark editor](mockups/workbench/workbench-390-dark.png), [390 light editor](mockups/workbench/workbench-390-light.png), [700 dark](mockups/workbench/workbench-700-dark.png), [light Explorer drawer](mockups/workbench/m0-narrow-light-explorer.png). Both themes/widths tested; drawers mutually exclude at ≤700, close on Escape and restore opener focus. | No document overflow in measured views. Nonmodal Explorer deliberately leaves a strip of editor visible. Drawers do not trap focus; touch/virtual-keyboard/zoom testing is still needed. |
| Narrow patch action reachability | [Dark review](mockups/workbench/agent-review-narrow.png), [light review](mockups/workbench/m0-narrow-light-proposal.png), [light permission](mockups/workbench/m0-narrow-light-permission.png), [deny](mockups/workbench/m0-narrow-light-denied.png), [cancel](mockups/workbench/m0-narrow-light-cancelled.png). Actions are visible and clicked successfully; post-deny/cancel focus returns to composer. | Code/diff lines intentionally scroll horizontally; end-of-line context is clipped in the still image, so screenshots alone cannot prove a reviewer inspected every byte. Per-hunk review, large patches and real device ergonomics remain future work. |

### Fixed prototype defect

**Availability mismatch in pickers:** after adding `notes-kit`, the Explorer add button disabled correctly but the command palette still offered a working “add sample root” option. The retained pre-fix run reproduces this as **one result where zero was expected**. Source inspection also found that code actions remained listed for a file without a diagnostic and the workspace picker offered the already-added root.

Minimal fix in [mockup.js](mockups/workbench/mockup.js): picker items may declare `enabled: false`; `openPicker` filters those items. Root addition checks whether `notes-kit` already exists; code actions check diagnostics for the active file. No new native capability or changed document model. `m0_command_availability` now asserts the palette and workspace picker hide unavailable root addition, hide inapplicable code actions, and still offer the applicable action on `main.zig`. All original and new cases passed afterwards.

### Limits and approval handoff

- Chromium only; no Firefox/WebKit, screen-reader, GTK, IME, actual touch, virtual keyboard, zoom or automated contrast compliance claim. Screenshots are review evidence, not pixel-golden tests.
- Memory fixtures only. Preview save/commit survive workspace switching but **not reload**. No real Git/compiler/LSP/PTY/provider/ACP operation is established here.
- `W02/W03/W05/W06` native invariants, M0 terminal feasibility, native regressions and benchmarks are **not closed** by these browser runs. Linked concurrent native fixtures require their owners' actual commands/results and integrated evidence.
- Request an explicit decision from the user/product owner on the workflow matrix, **D1 staged-only**, **D2 inert proposals**, **D3 recovery ownership**, and **D4 native scope**, including the partial-story boundaries above. Record approver, date, decision and any exceptions when that happens. **No such approval has been supplied or inferred in this document.**
