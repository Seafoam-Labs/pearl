# M2 closure: bounded workspace preview acceptance

**Implementation disposition: COMPLETE.** The final feature audit concludes that all mandatory M2 features are implemented. **M3 language intelligence is next.** M2 closes as a bounded native workspace preview, not a full IDE, Zed parity release or a revision of the accepted M0 engine decision. The consolidated final acceptance gate and hooks-disabled production build both passed; the precise fresh/cached results are recorded below.

## Mandatory scope and evidence map

| M2 requirement | Implemented behavior | Native / backend evidence |
| --- | --- | --- |
| Real multi-root workspace | Versioned manifests, typed roots, qualified labels, unavailable roots, async loading and watched publication | `tests/workspaces.py`; model/manifest/browser/watch units; [workspace guide](WORKBENCH_M2_WORKSPACES.md) |
| Responsive 100k discovery | Bounded paged virtualized explorer; on-demand Quick Open and streaming literal search, dirty overlays, explicit omissions/Refresh | `tests/explorer.py`, `tests/search.py`; [search limits and measurements](WORKBENCH_M2_SEARCH.md) |
| Settings and restricted-mode safety | Four safe settings with provenance/language overrides; separate explicit persistent trust; repository input cannot execute or grant itself authority | `tests/policy.py`, workspace no-execution fixtures; settings/trust units; [policy guide](WORKBENCH_M2_POLICY.md) |
| Docks and native pickers | Movable/resizable/hideable Explorer/Search; compact layout, Quick Open overlay, native Recent Projects/Open Buffers | `tests/docks.py`; project picker cases below; dock and workspace-picker widgets |
| Explicit checkpoints | One independent `sessions/current` slot; verified clean rebind, unsafe/dirty text as Save As copies | `tests/sessions.py`, session backend; [explicit guide](WORKBENCH_M2_SESSIONS.md) |
| Automatic projects and windows | Per-project/latest per-window and scratch snapshots, recents, ordinary startup, precedence, durable retirement, leases and atomic Forget | `tests/projects.py` **25/25**; project backend/controller tests; [project guide](WORKBENCH_M2_PROJECTS.md) |
| Root-management completion | Save Workspace As to a new destination; then reviewed immediate Add existing Folder / Remove Selected Root | `tests/roots.py` **18/18**; 16 root backend tests included in the main root; [root workflow](WORKBENCH_M2_PROJECTS.md#reviewed-workspace-root-management) |
| Independent multi-window ownership | Per-owner documents, workers, recovery, docks and search; coordinated saves and sequential Quit All | `tests/windows.py`; manager tests; [window guide](WORKBENCH_M2_WINDOWS.md) |
| Explicit file operations | Reviewed exclusive creation, bounded rename/move/permanent delete, process-wide document/root protection | `tests/operations.py` **25/25**; operation backend; [operation guide](WORKBENCH_M2_OPERATIONS.md) |
| Crash restores dirty work | Existing explicit recovery decisions, unsaved copies, layout/excerpts, interrupted publication and conflict protection | `tests/app_recovery.py` **13 groups**; M1 workflows/groups; recovery/session units |

The original M2 exit gate—real two-root workflow, responsive 100k fixture, crash restoration of dirty files, and untrusted workspace launching no process—is covered by this composed evidence. New project/root tests complement rather than replace existing M1/M2 gates. Native fixture controls are absent from normal production builds.

## W07: exact coverage, not an inflated single-test claim

The native M2 interpretation is **A → B via Open Folder/Workspace preserves documents; return to A through Recent Projects restores an independent owner or activates its matching live owner**. It is not isolated same-window tab-set switching.

| Exact case in `tests/projects.py` | What it asserts |
| --- | --- |
| `W07_colliding_roots_search_quick_open_identity` | Same-named files in two roots; Quick Open and text Search return distinct root IDs and open the selected file |
| `buffer_picker_group_excerpt_identity` | Filtered native buffer picker activates the intended group/full or excerpt view, preserving the other dirty document |
| `W07_A_B_A_dirty_untitled_groups_excerpt_docks_selection` | Rich A with dirty and untitled text, two groups, excerpt, directed selections and desired docks; switch to B retires A; Recent A restores a fresh independent window with semantic equality; B is unchanged; subsequent selection activates A rather than cloning; A edits do not leak into B |
| `closed_project_reopen_preserves_layout` | Close a clean project while another window remains; reopen through recents with layout/selection/excerpt equality |
| `automatic_no_cli_multiwindow_startup` | Quit two project windows, ordinary no-CLI launch, expected roots and distinct new IDs, and membership transferred from old IDs to the restored owners |
| `failed_retirement_preserves_old_project` | Retention failure prevents the switch and preserves old roots/documents; retry succeeds and old state can be restored |

**Coverage boundary:** `automatic_no_cli_multiwindow_startup` asserts roots and membership, not equality of every layout property. Full layout coverage is composed from rich W07, closed-project reopen, session and dock suites. The rich W07 case does **not** inject a pending operation during A → B. Existing workspace/search generation, activation, cancellation and late-reply races complement it; do not describe them as one all-in-one W07 scenario.

`tests/roots.py` closes the root-management portion with real case names:

- `native_palette`, `menu_chooser_cancel`: native menu/palette/chooser/review routing and cancellation.
- `folder_prerequisite_lastroot`: Save Workspace As prerequisite and last-root refusal.
- `samebasename_remove_dirty`: typed colliding root identity, no disk deletion or dirty-document loss.
- `preserve_policy_lexical`: settings/language overrides/excludes/names preserved; absolute lexical paths keep symlink/`..` meaning across Save As.
- `duplicate_alias`, `root_cap`, `cancel_reviews`, `destination_rejections`: alias/cap/refusal and no writes before review, no overwrite or implicit directory creation.
- `source_changed_prepare`, `source_changed_review`, `added_type_race`, `stale_generation_reply`: fresh source/model checks, replaced source, changed added directory and retired review rejection.
- `bound_owner`, `bound_peer_aliases`: clean/dirty open manifests and peer symlink/hard-link aliases, including late binding.
- `delayed_barriers`, `close_pending`, `cycles_and_drain`: apply admission through callbacks, close refusal until cleanup and bounded repeated cancellation.

Other project cases cover automatic debounce without a checkpoint hook; shortcut/menu/palette routing; CLI/recovery/empty-recovery precedence; two live processes and `three_concurrent_ordinary_startups_consume_member_once`; frozen delayed close, canonical fault rejection, cancel thaw, save failure, oversize opt-out; confirmed/live/stale Forget and 64-record refusal. The catalog-cap test uses an exact-ID test-controller action for an older item beyond the 50-row prefix; it is **not proof of unlimited native history addressability**.

## Confirmed closure evidence

Evidence paths below are local artifacts under `pearl/.cache`, not bundled release content. Earlier per-increment counts in the guides remain historical measurements and are not relabelled as current aggregate counts.

| Completed validation | Result / evidence |
| --- | --- |
| New project native suite | **25 passed / 0 failed / 0 blocked**, including the three-process startup race; [verified results](../../../.cache/coral-projects-25-verified/results.json) |
| New root native suite | **18 passed / 0 failed / 0 blocked**; [results](../../../.cache/coral-roots/results.json) |
| Fresh headless core | **325 main-root tests**, including the **16 root backend tests** and two added startup-claim regressions; earlier parent checkpoint was **323**, before those two tests |
| Separate project backend | **35 tests** at the reported parent validation checkpoint; separate from the main root, with overlapping transitive model/layout coverage |
| Prior nine aggregate gates rerun | All passed; [machine-readable gate summary](../../../.cache/coral-m2-regressions/gate-summary.json), with exact commands, log hashes and retained attempts |
| Widgets in that regression pass | **198 tests** in each of the eight widget-including gates; workspace slice does not run widgets |

The nine prior gates are `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search`, `test-m2-policy`, `test-m2-sessions`, `test-m2-docks`, `test-m2-windows` and `test-m2-operations`. Their native results are **40 workflows, 14 group/history, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions, 27 docks, 27 windows and 25 operations**. Runs were sequential with 600-second command bounds. Headless steps in aggregates may be cached; counts overlap and are not additive unique-test totals.

One sessions aggregate attempt passed its native **19/19** but hit the widget harness's unchanged **internal 60-second timeout at test 101/198**. The identical retry passed, including all 198 widgets. Both attempts are retained in the regression directory. Do not describe this validation campaign as having had no timeout, or silently replace the failed attempt with a clean-run claim.

### Final validation passed

**The complete `test-m2` aggregate passed: 84/84 build steps, exit 0, in 21m24s**, within its 30-minute command bound. All eleven constituent gates ran successfully, with shared dependencies deduplicated:

- **325/325 main-root tests freshly executed.** Four additional headless runners were cached, including the separately validated 35-test project backend; this run does not claim another fresh execution of those 35 tests.
- **198/198 widget tests executed once**, completing in 40.148 seconds.
- **271 native check groups across 13 harnesses**, each executed once: 40 workflows, 14 application groups, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions, 27 docks, 27 windows, 25 operations, **25 projects and 18 roots**. These are suite check groups, not an additive unique unit-test count.
- The subsequent hooks-disabled production build passed **46/46 steps**, exit 0, with fresh executable compilation in **23.6 seconds**.

No retry or threshold change was needed for this final consolidated run. No attributable private-session processes, temporary directories or new `/tmp` entries remained. Four pre-existing private-session directories were recorded and left untouched. The earlier widget timeout above remains part of the historical campaign evidence.

Evidence: [aggregate log](../../../.cache/coral-m2-final/test-m2.log), [production log](../../../.cache/coral-m2-final/production.log), [machine-readable validation and cleanup evidence](../../../.cache/coral-m2-final/validation-evidence.json), and [artifact SHA-256 hashes](../../../.cache/coral-m2-final/SHA256SUMS). Native test binary: `2a339cafcae8e5f76a1cd32c358f3bd75a524e8eefe64861c76095910489a468`; production binary: `47465ea91f8116000bce1477254d955083f63d9d536d357eeabdd329c9907fcc`. Source/test hashes were unchanged during validation. See also the [status checkpoint](WORKBENCH_STATUS.md#full-m2-validation-checkpoint).

## Build gates and reproducible environment

From `pearl/subprojects/coral`:

```sh
zig build project-unit -Doptimize=safe -j1 --summary all
zig build projects -Doptimize=safe -j1 --summary all
zig build roots -Doptimize=safe -j1 --summary all
zig build test-m2-projects -Doptimize=safe -j1 --summary all
zig build test-m2-roots -Doptimize=safe -j1 --summary all
zig build test-m2 -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all
```

`test-m2` is the complete bounded M2 target: the prior nine aggregates **plus** `test-m2-projects` and `test-m2-roots`, with shared build dependencies deduplicated. `project-unit` isolates fork-based publication/lease tests from the GIO worker pool and also belongs to `test`. Root backend tests are in the main headless root. Native harness-only targets are `projects` and `roots`.

**Generic launcher option:** `-Dnative-python=/absolute/path/to/python-or-validation-launcher` selects the interpreter/launcher for private native validation harnesses; default is `python3`. This is not a production dependency, a hardcoded runtime search path, or permission to weaken private-session isolation. A launcher receives the harness path and its arguments. The normal harness supports `-- --aqueous-prefix PATH` where passthrough arguments are exposed; use each individual target when selecting per-harness arguments.

### This host's private ICU78 recovery

Current tested toolchain: Zig **0.17.1**, GTK **4.24.1**, GtkSourceView **5.22.0**, Enchant **2.8.21**. This host currently supplies ICU79, but the older `/usr/lib/libxml2.so.16` dependency requires **`libicuuc.so.78`**. That affects Zig/Shelly and GTK/Coral transitively; Python itself starts. Validation recovered the **actual ICU78 ABI privately**, not by aliasing ICU79, downgrading packages or changing production dependencies.

The already-cached package was `/home/zoey/Projects/devario-os/work/repository-downloads/icu-78.3-2-x86_64.pkg.tar.zst`, metadata `icu 78.3-2`, x86_64, Seafoam Labs; SHA-256 `5834d55eebd506d4a6af396d9c8490fd10b8fa9558b054c3eba4cde32b9f434e`. Its detached signature was not independently verified. Only versioned `usr/lib/libicu*.so.78*` members were extracted into `/home/zoey/Projects/pearl/.cache/coral-m2-runtime/lib`; no unversioned linker symlinks or ICU79 substitutions were added. No download, host package operation, global library modification or production dependency change was made.

Pearl's private harness sanitizes inherited loader variables. The cache-only `run_harness.py` prepends this exact runtime to private child/run environments while retaining the verified wlroots path and all private HOME/XDG/Wayland isolation. An outer `LD_LIBRARY_PATH` alone is insufficient for those children. Literal host command:

```sh
env LD_LIBRARY_PATH=/home/zoey/Projects/pearl/.cache/coral-m2-runtime/lib zig build test-m2 -Doptimize=safe -j1 -Dnative-python=/home/zoey/Projects/pearl/.cache/coral-m2-runtime/run_harness.py --summary all
```

The same outer environment can launch the hooks-disabled production validation build; the private path is **not** linked into production. Do not set `LIBRARY_PATH` or `PKG_CONFIG_PATH` to this recovery directory. [Runtime provenance and smoke evidence](../../../.cache/coral-m2-runtime/README.md) record 32 dependency scans without missing libraries, ICU78/79 coexistence and loaded paths. This environment uses **Shelly**, not pacman/makepkg; repository PKGBUILDs are packaging targets, not host identification. Inspect Shelly commands before any future package operation.

## Accepted limits and next milestone

M2 implementation completion retains these explicit boundaries:

- **GtkSourceView stays.** Accepted M0 syntax/long-line policy and bounded-excerpt fallback are unchanged. Full giant-line rendering remains unsupported; original input-to-paint targets remain unverified and recorded timing misses remain misses. Historical M0 documents are not rewritten by this closure.
- Bounded explorer pages and on-demand search are not a persistent recursive index; no workspace-wide replace or unlimited result sets. Local input acknowledgement is not paint latency.
- Automatic retention is capped at 64 records / 16 startup members / 256 MiB; snapshots are capped at 4 MiB/document and 8 MiB text. No silent dirty eviction. Pickers capture at most 512 items and display the first 50 matches, not arbitrary pageable history.
- Root management has no dedicated rename/reorder controls, overwrite-existing Save Workspace As, implicit new roots, disk deletion or document closing. Semantic JSON preservation is not formatting preservation.
- Explicit checkpoint and crash-recovery formats remain separate from automatic catalog publication. No missing-manifest fallback, unlimited backup history, cross-window shared buffers/tab transfer, or desktop window-position restoration is claimed.
- Filesystem checks, advisory leases and process-local mutation barriers are not hostile-filesystem sandboxing. Mount calls can block; crash/fault tests are not physical power-loss certification. Normal Save/Discard remains required after automatic-retention opt-out.
- M3–M8 still own LSP, Git/review, production terminal/tasks, native and ACP agents, MCP, DAP/test UI, extensions, advanced editing and full accessibility/IME qualification. Remote workspaces and other roadmap exclusions are unchanged. **M9 remains removed.**

**Next: M3 language intelligence**, against the existing document/workspace/trust contracts, not more mandatory M2 feature implementation. The [implementation plan](WORKBENCH_IMPLEMENTATION_PLAN.md) remains the later-milestone roadmap.
