# M0/M1 engine benchmarks, build wiring, and qualification decision

Updated 2026-11-08 on `zoey-machine`, after the final safety/save-generation fixes. **Engineering decision: retain GtkSourceView with canonical documents, independent presentations, grouped history and explicit bounded presentation policies for the foundation.** Native correctness/build acceptance is green, and the **1 MiB retained-source fallback now completes five cycles and 1,000 samples in both wrap modes**, as does B05. The old incomplete-fallback claim is superseded. Full giant-line rendering remains unsupported and guarded in production, strict proposed timing screens are still missed, and real injected-input-to-paint remains unverified. These are performance/product qualification obligations, **not functional incompleteness of M1 or absence of the corresponding code features**.

Authority: [WORKBENCH_M0_REFERENCES.md §5](WORKBENCH_M0_REFERENCES.md#5-minimal-m0-benchmark-methodology-and-gates). Proposed gates cannot be silently redefined by a benchmark runner or by rounding a measured miss down to the threshold. The tradeoff checklist at the end records the decisions subsequently accepted by the user to proceed to M2; measured results are unchanged.

## 1. Scope and current commands

All commands below run from `pearl/subprojects/coral`, using Zig **0.17.0**, optimization **safe**.

```sh
zig build -Doptimize=safe --summary failures
zig build test-m1 -Doptimize=safe --summary all
zig build build-benchmarks -Doptimize=safe
zig build benchmarks -Doptimize=safe
```

`test-m1` includes root/appearance unit tests, widgets, existing native workflows, app groups, and app recovery. Individual `test`, `widgets`, `integration`, `app-groups`, and `app-recovery` targets remain available. Native harnesses use the same test-hook-enabled application artifact; production installation does not gain those hooks. Native output defaults to private `pearl/.cache/coral-native`, not tracked screenshots.

Benchmark operations and fixture generation are Zig (`src/benchmark_m0.zig`). Python (`tests/benchmarks.py`) is validation orchestration: isolated sessions, watchdogs, source archives, overlap checks, raw logs and nearest-rank statistics. No app/main/recovery/editor implementation was edited by the benchmark owner. Other agents' policy, recovery and workspace-identity integration is included in the measured source snapshots.

### Exact final timing runs

Reports are under `pearl/.cache/coral-benchmarks/`. Each run has raw session logs, per-trial JSON, aggregate `results.json`, `dirty.diff`, and `sources.tar.gz`.

| Command | Report | Result |
| --- | --- | --- |
| `zig build benchmarks -Doptimize=safe -- --workload B05 --workload B03-bounded-excerpt --bounded-bytes 1048576` | **`run-ldrbm59w`** | **Final safety-fixed targeted run: exit 0, three trials, zero failures.** B05 and both retained-source 1 MiB fallback variants each completed **five cycles / 1,000 samples**, with unchanged 180 s / 120 s watchdogs. |
| `zig build benchmarks -Doptimize=safe -- --workload B01 --workload B02 --workload B03 --workload B04 --workload B05 --workload frame-probe --workload transport` | `run-zcphbkha` | **92 trials**, exit 1. B01/B02/B04/B05 and frame probe complete; two genuine 60 s B03 failures. Transport completed but was falsely marked as overlapping validation by the first overlap detector; its independent rerun below supersedes that classification. Raw report retains all three failure records. |
| `zig build benchmarks -Doptimize=safe -- --workload B03-bounded-excerpt --bounded-bytes 65536` | `run-skryjl8c` | Exit 0, **two variants**, each **five cycles / 1,000 samples**, source view retained. This is explicitly a **64 KiB** long-line source, not a replacement for 1 MiB B03. |
| `zig build benchmarks -Doptimize=safe -- --workload transport --workload frame-probe` | `run-w37br73h` | Exit 0, two complete trials; corrected overlap detector, no overlapping validation observed. |

The final pass ran **only B05 and retained-source 1 MiB bounded excerpts**, not the older comprehensive command again. No fixture or production code changes were needed. B01–B04/full-render B03 and frame/transport values below retain their explicitly identified earlier source revisions; they are not retrospectively attributed to the final executable.

Default `benchmarks` attempts the **1 MiB** bounded-excerpt variants, which now complete under their original watchdogs. `--bounded-bytes 65536` explicitly selects the earlier smaller policy case. `--bounded-close-source` selects another separately named real workflow: close the guarded full-source view after opening its excerpt. Neither option changes full B03 or lowers sample counts.

Bounds: B01 15 s per launch; B02 1 MiB 180 s / 10 MiB 60 s per trial; B03 full render 60 s plus a **10 s load/layout alarm**; B04 180 s per tab-count process; B05 180 s; bounded excerpt 120 s per variant; frame probe 15 s; transport 30 s. A drain has a 10 s elapsed-time bound. No cache dropping or system power-setting changes were performed.

## 2. Reproducibility and source stability

The build takes a source snapshot **before benchmark compilation**. The runner requires its conservative local Zig import closure to match that snapshot before executing. It records full-tree and benchmark-closure hashes before/after, exact changed paths, executable SHA-256, build optimization, command invocation, library versions, fixture/output hashes, machine details and raw samples. Archives include untracked implementation files, not just the tracked diff. This is not a vendored archive of the compiler, OS or every dependency package; retain the pinned dependency/toolchain environment too.

**Final targeted report `run-ldrbm59w`:** full captured sources and the benchmark import closure were stable across a five-second preflight, matched the pre-compilation snapshot, and remained unchanged throughout all three trials (`source_changed_paths: []`, both change flags false). No competing validation was observed. The source capture covers `src`, `resources`, build inputs and harness/support files; **`docs` is excluded**, so concurrent parent documentation work does not invalidate engine stability. The tracked dirty diff may include documentation; its recorded identity describes the snapshot at capture, not an additional code-change detector.

The earlier `run-zcphbkha`, `run-skryjl8c`, and `run-w37br73h` also recorded unchanged sources within each run and shared an earlier executable. Their only harness-manifest difference was the correction excluding owned forked supervisors from competing-process detection. They are retained as earlier comprehensive evidence, not the final safety-fixed executable's full-suite qualification.

The runner waits up to 60 s for known competing build/native/widget/browser/benchmark work to finish before each trial and samples for overlap every two seconds during a trial. Detected overlap invalidates timing qualification, never kills another agent's job. This is a best-effort check for known validation processes, not proof of an idle dedicated machine or absence of arbitrary host activity. No external competing validation was observed in the final targeted run or the earlier B01–B05/64 KiB policy trials. The benchmark owner's earlier `test-m1` run followed that earlier timing work. The latest full acceptance run/counts are parent-owned; this final pass intentionally ran no extra test suites.

HEAD: `dee722fe018c5db3d864ad905c9f9157f794b4fe`, dirty integration tree. HEAD alone is insufficient provenance.

| Identity | SHA-256 |
| --- | --- |
| **Final executable, `run-ldrbm59w`** | `b95e2a8d29ad27bb52f62fc491bb6ea4ef51272ccb3ba3bfc29b3fd9218e31c4` |
| **Final benchmark source/import closure** | `8506154212eae35a8eb542eae9b94241fdc1bfbeb2197ccabb441edc415be627` |
| **Final broader source manifest** | `5c3999f0e1076644d6ff426db161c47b7b3df7ffe3474b74a2ea8329041d6c8e` |
| **Final tracked dirty diff** | `0b806f1c0e2af8a350ea0890b938768a5942cbcc5be6f7f36eec3d19d072d9f6` |
| **Final source archive** | `13e05e2d8c53715eb8d506e73f07b800eaa389f0e2e38f2f96a125bea7c19a0b` |
| Earlier executable, `run-zcphbkha` / `run-skryjl8c` / `run-w37br73h` | `9986b5405d86de5da5fd517c68c43a2dcf9a44acf796529623cf28a268501594` |
| Earlier benchmark source/import closure (those three) | `1e16b179112c9cc26a6ddebeb4ead90d1e0aacf335d47d72bd2be9630e69c6c4` |
| Broader source manifest, `run-zcphbkha` / `run-skryjl8c` | `debdd405200838da1b8721d67955b00d493d8b63201852fcadea0678652aa349` |
| Broader source manifest, corrected harness `run-w37br73h` | `2ac594bb63cfb1f9d3439d3801c3f1622c2e54d200f175b65ad0b41e1d5cc7f8` |
| Earlier tracked dirty diff (those three) | `7e8099266daea49970d5c9d3b6622fb65ddf5ab91151ede183fe79b65337b6e3` |
| Source archive, `run-zcphbkha` | `60dc4ce2b75de6f09156c991040dc15fc5c5bf81401935837e1433055493141b` |
| Source archive, `run-skryjl8c` | `67a82481b130b3a3079374ad67baff81c9617b309a9c70b7cce3ee20f62a5862` |
| Source archive, `run-w37br73h` | `89a56af71098f91f966a9b54e66820ea7887ccc5878e01447b0acf4968c5edb5` |

Archive hashes can differ for identical source contents because archive timestamps differ; the source-content manifest is the comparison identity. Final report validation verified archive and dirty-diff SHA-256 values, all **75 archived files** against the recorded manifest, all three 1,000-sample/five-construction populations, and both fallback variants' five restored hashes and policy records. `git --no-pager diff --check -- docs/WORKBENCH_M0_BENCHMARKS.md` passed.

### Reference environment

- AMD Ryzen 9 9950X3D, 16 cores / 32 logical CPUs, boost enabled; **129,483,692 KiB RAM**.
- ext4 on `/dev/nvme1n1p2`, Samsung SSD 980 PRO 2 TB; a WD_BLACK SN850X HS 2 TB is also present.
- Linux x86_64 `7.3.3-1.1-devario-llm`; power profile **performance**. Governor readings, CPU details and memory/storage probes are retained in JSON.
- Zig **0.17.0**, GTK **4.24.1**, GtkSourceView **5.22.0**, Enchant **2.8.21**.
- Private Aqueous **1.0.18**, private HOME/XDG/session bus. No provider/network workload or imported host session bus.
- Actual compositor renderer **Vulkan / AMD RADV RAPHAEL_MENDOCINO** despite PrivateSession requesting pixman. Compositor logs are authoritative. GTK uses **cairo**. The RTX 5090 and llvmpipe are other enumerated devices.
- Headless outputs **1280×720**, scale **1**; `wayland-info` advertises **0.000 Hz**. This is not a physical-refresh reference system.
- Requested window 1000×700 logical pixels; actual B01 allocation **765×429**, scale 1. Runtime allocation records are included.
- GTK **Adwaita**, **Adwaita Sans 11**; monospace editor widgets; `fc-match monospace` resolves **MonoLisa Variable Regular**.
- Canonical undo/search context/spelling tag are present; the full app spell worker, file watchers, recovery controller, app CSS and application launch path are **not** part of the engine timing driver. Correctness for those paths is exercised by native tests instead.

## 3. Fixture, policy and clock contracts

Source lines are exactly **64 UTF-8 bytes**: start with spaces, write `// {id:0>3} const café = "λ🌱"; // deterministic` at byte zero, set byte 63 to LF, repeat to exact size. Single-line fixtures use a space instead of LF. Sizes are multiples of 64, so UTF-8 is never truncated. IDs 0–99 give distinct tab contents.

| Fixture (id 0) | SHA-256 |
| --- | --- |
| Empty | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| 1,048,576 bytes, LF | `e61d72263dd9309875b2ad14b740f8bcff17c1c673ed8b25df18082c4a2f1be8` |
| 10,485,760 bytes, LF | `fb70a96fae53795de2bd27e061f6b9f48aafcc564feeeeccf8d99a8c99f7eb1d` |
| 1,048,576 bytes, no LF | `8a993eacf3a08f47fdffb603534872d91db0c5891d70a13ad04c3639f9b1ec15` |
| 65,536 bytes, no LF (explicit smaller fallback) | `bc8264318b2a5c2ce4424cc10e030857a4984751d47ee56703f6388852678597` |

Per-document 64 KiB hashes and restored-output hashes are in the raw records. B01 uses real private files generated before launches; Zig checks GIO save/readback identity and that cancelled replacement preserves bytes. This untimed setup is not mixed into startup samples.

### Production policy and explicit tradeoffs

The measured engine now uses `presentation_policy.zig`:

1. Disable syntax language processing at **>=512×1024 GTK characters**, or for a paragraph **>16×1024 bytes**. The first limit is characters, **not bytes**. Normal-sized documents retain syntax. These are explicit performance tradeoffs, not normal-feature parity claims for every file size.
2. `layout_guard.zig` replaces full giant-paragraph layout with a visible explanation and an offset selector/action. The hidden GtkTextView is now parked on a separate buffer so it does not continue processing giant-paragraph layout while unmapped; the authoritative presentation and canonical buffers remain intact. Source text, identity, directed selections, save and undo are preserved within the checked-edit policy.
3. The action opens an excerpt initially containing **up to 2,048 characters** at a canonical character offset. The benchmark uses the production guard button, policy, excerpt mapping, widget and history; only controller glue reproduces `App.openBoundedExcerpt`'s character-to-byte conversion. An insertion temporarily grows the excerpt to 2,049 characters before undo. The creation limit is not a hard maximum editable document size or a virtualized whole-line renderer.
4. **Full B03 is an explicit control bypassing only the layout guard.** A separate raw GtkSourceView renders the entire production presentation buffer, with wrap off/on independently. It does not time an invisible guarded widget and does not re-enable syntax processing prohibited by production policy. Its recorded failures remain failures; full rendering is unsupported and guarded in production, and was not rerun in this final targeted pass.
5. A guarded source **over the 16 MiB checked-edit limit** truthfully disables its bounded-edit button/offset control and explains the limitation; saving an unchanged copy remains available. A 2,048-character excerpt is not a promise of checked editing for arbitrarily large canonical sources. The final 1 MiB benchmark is below this limit and does not independently test the >16 MiB negative case.

The final source archive includes the app/parent safety fixes: reverse byte-cached GTK reads, hidden-view parking, guarded native typing epochs in `native_history`, sticky stale-save state in `document`, and **O(1) save-generation checkpoint metadata** instead of whole-buffer clean-state comparisons. O(1) describes that checkpoint bookkeeping, not every edit/undo operation. These are production-owner changes; this benchmark/report pass altered no implementation or fixture.

### Timing and correctness rules

- **B01:** monotonic time just before OS process creation to mapped/focused/programmatic-edit-and-undo probe; includes GTK startup, real fixture read, construction and fixed settling. New private config/cache/state/data for each first-process/cache-unspecified launch; paired warm launch reuses them. Neither is cold page-cache measurement or first-presented application readiness.
- **B02/B03:** direct buffer insert, delete, undo deletion, undo insertion, each through nonblocking main-context drain. Ten excluded warm-up cycles; 250 measured cycles × four operations = **1,000 samples** per completed variant. Beginning/Unicode, middle and end rotate. Full B03 also records caret/horizontal-scroll requests separately.
- **B02 panes:** independent presentation buffers share one canonical document; the second cursor at character 3 must not move. Periodic/final canonical and mirror content checks verify restoration.
- **B04:** five reopen cycles per 1/20/100-tab variant; distinct 64 KiB documents; all tabs activated each cycle; 50 four-operation edit cycles after ten warm-ups = 1,000 input samples total. Separate second-view creation, exact restored bytes, and close-to-zero counts are checked. Notebook scrolling matches production.
- **B05:** ten 64 KiB sources × ten 20-line excerpts (source lines 0,30,…,270), separate headers, one read-only historical widget, one full-source view: **102 presentations**. First/middle/last excerpts 0/50/99 form one three-document history edit. Five cycles × 100 edit/undo pairs = **1,000 samples**, excluding ten warm-up pairs per cycle. Actual coalesced source-change idle refresh is exercised; external source edit/refresh and exact restored bytes are checked too.
- **Bounded-excerpt policy case:** five independent document/view reopen cycles, canonical window offsets beginning/middle/end, 100 edit/undo pairs per cycle after ten warm-ups = **1,000 samples per wrap variant**. Assert full layout guarded, notice mapped, bounded editor mapped/editable, syntax policy active, canonical insertion at the correct Unicode location, undo, exact source/excerpt bytes, and final close counts. Canonical source size and whether the full-source view remains open are always in the trial name/records.
- Individual GLib dispatches **>50 ms** are separate `stall` records. Zero recorded maximum means none crossed that threshold, not a zero-time loop. Operation-plus-drain duration is not necessarily one uninterrupted dispatch.
- Nearest-rank p50/p95/p99 use `ceil(p*n)`. Microseconds are preserved in JSON. Partial counts and timeouts are retained, not discarded.

**Crucial interpretation:** rapid programmatic edit/delete/undo bursts can finish before a frame is presented. Fast B02 buffer timings therefore do not prove keystroke-to-paint performance. The full app feature mix and physical presentation remain separate qualification work.

## 4. B01–B05 results by recorded source revision

Times below are **milliseconds**. “Complete” means the requested engine workload and local invariants completed, not that a presentation target passed. **B05 is refreshed on the final safety-fixed source below; B01–B04 are retained from `run-zcphbkha` and were not rerun in the final targeted pass.**

### B01 — real-file startup proxy

| Fixture/class | n | p50 | p95 | p99 / max |
| --- | ---: | ---: | ---: | ---: |
| Empty first-process/cache-unspecified | 20 | 77.384 | 79.846 | 80.000 |
| Empty warm | 20 | 77.373 | 79.834 | 79.860 |
| 1 MiB first-process/cache-unspecified | 20 | 263.892 | 267.206 | 267.362 |
| 1 MiB warm | 20 | 263.943 | 265.806 | 269.175 |

All 80 launches completed. First-input-ready **application presentation** is still unverified; these are engine startup/read/edit-probe clocks, with syntax limited by production policy for the large document.

### B02 — multiline canonical/presentation input

| Source/panes | n | p50 | p95 | p99 | max | Opened → edited RSS, KiB |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 MiB / 1 | 1,000 | 0.032 | 0.035 | 0.039 | 0.564 | 76,652 → 78,740 |
| 1 MiB / 2 | 1,000 | 0.054 | 0.079 | 0.084 | 1.134 | 80,792 → 82,924 |
| 10 MiB / 1 | 1,000 | 0.033 | 0.036 | 0.055 | 0.986 | 144,484 → 167,044 |
| 10 MiB / 2 | 1,000 | 0.055 | 0.079 | 0.134 | 1.561 | 181,000 → 203,536 |

All four completed, exact restored hashes matched, independent-pane checks passed, and final document/view counts returned to zero. Load/map/settle: **240.733 / 411.545 / 1,829.277 / 3,504.617 ms**, respectively. No >50 ms dispatch recorded. These supersede earlier pre-policy B02 timeouts/slow timings. They **do not** pass the original 16/32 ms paint target by proxy.

### B03 — full 1 MiB paragraph, guard deliberately bypassed

| Wrap | Load/map/settle | Measured input samples | Result | Maximum recorded dispatch |
| --- | ---: | ---: | --- | ---: |
| Off | 1,310.662 | **23 / 1,000** | **60 s timeout** | 477.612 |
| On | 5,887.134 | **0 / 1,000**, still in excluded warm-up | **60 s timeout** | 3,154.866 |

Both load trials were within the separate 10 s load bound, but neither completed steady input. Wrap-off partial input p95 **1,038.603 ms**, max **1,045.115 ms**: descriptive only, not qualifying percentiles. Opened RSS/peak: **336,800/337,968 KiB** off; **668,956/670,884 KiB** on. No post-timeout restoration/close assertion is made. **Full B03 remains failed**, not “passed with fallback.”

### B04 — tabs and independent second view

| Tabs | Cycles / input n | Combined input p50 / p95 / p99 / max | Insert-only p95 | Switch n / p95 | Open p95 |
| --- | --- | --- | ---: | --- | ---: |
| 1 | 5 / 1,000 | 3.356 / 7.234 / 7.332 / 7.403 | 7.329 | 5 / 0.001 | 55.950 |
| 20 | 5 / 1,000 | 3.297 / 14.030 / 17.466 / 17.939 | **17.431** | 100 / 0.032 | 414.239 |
| 100 | 5 / 1,000 | 3.318 / **17.428** / 17.961 / 20.229 | **17.849** | 500 / 0.026 | 1,921.776 |

All cycles completed with restoration checks. Switch values are request-plus-drain, not switch-to-visible. Second-view construction p95: **1.153 / 1.381 / 1.953 ms**. Do not hide the 20-tab insert-only miss behind a mixed edit/delete/undo population. Strict 16 ms proposed ordinary-input screening misses remain performance qualification items.

First-cycle RSS, KiB:

| Tabs | Empty notebook | Open | Edited | Extra view | Incremental open per document | Extra-view increment |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 58,440 | 70,588 | 70,920 | 70,920 | 12,148 | 0 |
| 20 | 58,208 | 95,016 | 96,904 | 96,904 | 1,840.4 | 0 |
| 100 | 58,256 | 199,456 | 204,264 | 204,372 | 1,412 | 108 |

These include shared GTK/allocator costs; a zero RSS increment is not a zero-allocation claim. All stage document/view counts and kernel RSS/peak values are in raw records. Settled post-close sequences:

- 1: **71,012, 71,060, 71,092, 71,180, 71,196 KiB**.
- 20: **97,024, 97,788, 97,788, 97,972, 98,612 KiB**.
- 100: **203,792, 205,232, 206,812, 207,952, 208,844 KiB**.

None exceeds the reference warmed-baseline growth screen `max(10 MiB, 5%)`. Retained RSS is not thereby proven leak-free. Maximum >50 ms dispatch records for 20/100-tab processes were **141.289 / 708.300 ms**, including setup; do not attribute the whole-process maximum specifically to steady input.

### B05 — final safety-fixed grouped excerpts

Final `run-ldrbm59w`: **five complete cycles, 500 grouped edits + 500 grouped undos**, all exact source/excerpt/full-view/historical-text checks passed. Trial elapsed **18.986830 s** under the unchanged **180 s** watchdog.

| Metric | n | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Construct/map/settle 102 presentations | 5 | 175.798 | 191.290 | 191.290 | 191.290 |
| Grouped edit + refresh/drain | 500 | 18.049 | **18.186** | 18.250 | 18.775 |
| Grouped undo + refresh/drain | 500 | 14.268 | 15.300 | 15.365 | 15.525 |
| Combined input | 1,000 | 15.525 | **18.155** | 18.222 | 18.775 |
| External source edit + explicit refresh/drain | 5 | 9.522 | 11.061 | 11.061 | 11.061 |

No dispatch exceeded the 50 ms recording threshold. Initial construction is below the proposed 250 ms screen. **18.186 > 16.000 ms: the strict edit p95 screen is missed.** The earlier approximately 16 ms results are not the final safety-fixed baseline. Do not call grouped excerpts absent or M1 functionally incomplete because of this performance miss. Actual event-to-visible qualification is separate.

Verified preceding optimization evidence supplied by the app agent:

| Report | Edit p95 / p99 | Undo p95 / p99 | Complete |
| --- | --- | --- | --- |
| `run-r5jl5l_v` | **16.009 / 16.089 ms** | 15.399 / 15.455 ms | five cycles, 1,000 samples |
| `run-l02cg2vu` | **16.100 / 16.207 ms** | 15.494 / 15.574 ms | five cycles, 1,000 samples |

Those reports share executable `9bdcc4ff74360ef0bd5f34984f79c6de7078fb44b2cb1e2b83976902ea78f231`, source manifest `a178020f4818bac257e958ffbf137a983a29e352b25defceccae6f5bd15eb181`, and unchanged source during each run. They are independent earlier provenance, not retroactively attributed to the new driver. Old 54 ms/pre-optimization or timeout-era excerpt numbers are not the current baseline.

The intervening `run-zcphbkha` recorded edit p95 **16.041 ms**; the later supplied safety-fixed `run-ktzv0ex_` recorded edit p95 **18.084 ms**, undo p95 **15.351 ms**. Both are superseded for the current B05 baseline by `run-ldrbm59w`. The supplied safety-fixed report's separate provenance is recorded in §5.

Final first-cycle B05 RSS: sources **55,668 KiB**, open **92,900 KiB**, edited **113,244 KiB**. Final closed sample: zero documents/views, RSS **112,656 KiB**, reported peak **113,144 KiB**. These are recorded stage snapshots, not a reconstructed maximum across all records.

## 5. Separately named bounded-excerpt production-policy workload

**Final `run-ldrbm59w` completed the requested 1,048,576-byte single-line canonical source**, real production guard, initially **2,048-character** editable excerpt, with the guarded full-source view **retained**. Each wrap variant completed **five cycles and 1,000 measured samples (500 edits + 500 undos)**. Wrap-off elapsed **18.436135 s**, wrap-on **19.137587 s**, both within the unchanged **120 s** watchdog. This demonstrates usable bounded fallback at 1 MiB, not a full 1 MiB line-render pass, a paint-latency result, or universal responsiveness at all source sizes.

| Variant | Edit p50 / p95 / p99 / max | Undo p50 / p95 / p99 / max | Combined p95 / p99 | Construct p95 |
| --- | --- | --- | --- | ---: |
| **1 MiB retained, wrap off** | 21.142 / **21.474** / 21.578 / 22.599 | 11.927 / **12.598** / 12.666 / 12.984 | 21.420 / 21.528 | 158.354 |
| **1 MiB retained, wrap on** | 22.049 / **22.319** / 22.452 / 26.266 | 12.328 / **12.957** / 13.003 / 14.679 | 22.254 / 22.357 | 161.245 |

No >50 ms dispatch was recorded. Both edit p95s exceed a strict 16 ms screening budget; successful completion does not waive that qualification. All five policy records per variant assert guarded full layout, mapped excerpt, syntax limitation and initial 2,048 characters; the trial configuration retains the source view. Canonical character offsets across cycles were **0, 483328, 964608, 0, 483328**. Each variant's five restored full-source hashes matched the 1 MiB no-LF fixture **`8a993eacf3a08f47fdffb603534872d91db0c5891d70a13ad04c3639f9b1ec15`**. Final document/view counts were zero.

First-cycle opened RSS was **82,044 / 82,268 KiB**, edited **93,300 / 93,528 KiB** (wrap off/on). Cycle-five closed RSS was **74,080 / 79,200 KiB**, reported peak **93,112 / 92,888 KiB**; the subsequent main final closed snapshots were **73,052 / 78,172 KiB**. These are stage-specific recorded values.

### Separately verified preceding safety-fixed evidence

Both supplied reports completed five cycles and 1,000 samples per variant with unchanged sources:

| Report / 1 MiB workflow | Edit p95 / p99, wrap off; wrap on | Undo p95 / p99, wrap off; wrap on |
| --- | --- | --- |
| `run-ktzv0ex_`, source view retained | p95 **21.423; 22.469 ms** | p95 **12.734; 13.060 ms** |
| `run-1_n44e2x`, source view closed | **15.861 / 16.023; 16.847 / 17.013 ms** | **8.870 / 9.068; 9.624 / 9.743 ms** |

These share executable **`0f8999ae60f51744c554be94dd9ed50b454d2ed48210ee2479284e9148dc2f2a`** and engine closure **`6e3adc1ebe59b8dbdb99a074053c98d16c74b2f53b4415f05178e9624dc2d9f4`**. They precede the final O(1) save-generation bookkeeping change and are not attributed to the final executable. The source-closed alternative was not rerun in this final retained-source-only pass.

### Earlier smaller fixture and superseded historical failures

`run-skryjl8c` completed a **64 KiB**, not 1 MiB, source with five cycles/1,000 samples per variant. Edit p95/p99 was **15.185/15.786 ms** wrap-off and **16.233/16.284 ms** wrap-on; undo p95 **14.429/14.756 ms**, construction p95 **101.684/103.284 ms**. This earlier smaller demonstration remains separate evidence, no longer the only completed fallback size.

- `run-1vbhk_8d`: older guarded-source-retained variants hit **120 s**, reaching **236 / 235** samples. This exploratory run overlapped another agent's native suite and is diagnostic history, not a final timing baseline.
- `run-0q41qzyp`: older source-view-closed variants, still with a full canonical **1 MiB**, hit **120 s**, reaching **744 / 740** samples and four constructions. Source remained stable. Edit p95 **197.286 / 198.141 ms**, undo p95 **131.883 / 132.904 ms**.

Those failures are **superseded for current fallback capability** by the safety-fixed supplied reports and final retained-source run; they are retained rather than erased. The requested **1 MiB / 1,000-sample / five-cycle fallback measurement is now complete without extending its watchdog**. The reverse byte-cached reads and hidden-view parking fixed the earlier pathological work; no benchmark fixture change was needed. Successful fallback still cannot silently replace original full-render B03.

## 6. Frame timing feasibility: useful feedback, original target still unverified

Added a separate **20-sample GDK frame probe**, without inserting frame waits into B01–B05 and changing their clocks. For each programmatic Unicode insertion, it records the monotonic operation start, requests a later frame/paint, waits up to 250 ms, and reads `GdkFrameTimings` only after `get_complete`. Both zero timestamps and absent feedback remain raw records, never a claimed presentation sample. Frame counter, completion-observation time and GDK-reported presentation time are retained.

Earlier dedicated probe `run-w37br73h`: **20/20 complete, nonzero GDK presentation timestamps**. Programmatic update → GDK-reported presentation: p50 **15.906 ms**, p95 **31.884 ms**, p99/max **32.005 ms**. The main B01–B05 run's independent probe was consistent: p50 16.002, p95 31.894, max 31.934 ms.

This is real **GDK-reported frame/presentation feedback**, not a timer labelled as paint. Limitations:

- No injected input event timestamp; operations are programmatic.
- The probe uses a small document, not 1 MiB/B05 workloads.
- It verifies final buffer synchronization, **not screenshot/pixel content for each specific frame**.
- Headless compositor feedback is not physical scanout measurement.

Therefore **original keystroke/event-to-presented-expected-text targets remain unverified**. The GDK evidence proves an instrumentation path is available; a future qualifying harness must correlate real event injection and expected content to the presented frame for each required workload.

## 7. Process/PTY supplement and optional harness targets

Earlier dedicated supplement `run-w37br73h`: fixed literal `/bin/printf` argv, cwd `/`, empty child environment, UTF-8 `héλ🙂`, exact output/exit/reaping checks. PTY also requests 41×109 resize. **20 samples each**:

| Metric | p50 | p95 | p99 / max |
| --- | ---: | ---: | ---: |
| Process capture → completion/reaped | 157.575 | 157.743 | 157.908 |
| PTY start → resize/read/EOF/reaped | 157.288 | 157.473 | 157.546 |

The first overlap detector flagged forked private supervisors retaining the benchmark executable's argv. It now excludes the owned descendant tree. `run-zcphbkha`'s raw false-positive record is preserved; the corrected independent rerun passes. No terminal rendering claims are inferred from these transport clocks.

### Optional GTK4 VTE spike target

`terminal-spike` only runs the existing harness against **explicitly prebuilt fixtures**. It introduces no VTE dependency, compilation or installation edge into the production/default/test-m1 targets. See [WORKBENCH_M0_TERMINAL.md](WORKBENCH_M0_TERMINAL.md) for fixture build and license boundaries.

```sh
zig build terminal-spike -- --help
zig build terminal-spike -- \
  --binary ../../.cache/coral-terminal-spike/spike-fixture \
  --child ../../.cache/coral-terminal-spike/spike-child \
  --vte-prefix ../../.cache/coral-terminal-spike/prefix
```

Both were executed. Acceptance **passed all four scenarios**: exit, cancel, close, exit. Evidence: `pearl/.cache/coral-terminal-spike/evidence/results.json`. This supports the separate terminal-feasibility decision; it is not M5 production integration or shell escape containment.

### Optional prototype target (not default or test-m1)

`prototype-m0` is registered **only** when `-Dprototype-python=...` names an existing prepared Playwright venv. `PLAYWRIGHT_BROWSERS_PATH` must explicitly select the prepared offline browser directory. Missing configuration fails instead of installing or downloading dependencies.

```sh
PLAYWRIGHT_BROWSERS_PATH=/home/zoey/Projects/pearl/.cache/coral-workbench-validation/browsers \
  zig build prototype-m0 \
  -Dprototype-python=/home/zoey/Projects/pearl/.cache/coral-workbench-validation/venv/bin/python \
  -- --help
```

Omit `-- --help` for the full browser review; `-- --only SUBSTRING` is an explicitly partial run. **The existing harness writes screenshots/reports under `docs/mockups/workbench`**. This owner verified the help/venv wiring only, not a new full browser run, to avoid modifying another owner's documentation artifacts. Use the absolute venv path to avoid Python's relative-prefix warning. No browser benchmark or UX approval is inferred from help succeeding.

## 8. Test/build acceptance and ownership

**Earlier independently executed regression evidence:** after the earlier comprehensive benchmarks, the captured source tree was unchanged over a five-second check. This benchmark owner executed:

```sh
zig build test-m1 -Doptimize=safe --summary all
zig build -Doptimize=safe --summary failures
```

Results for that earlier revision, **not the latest acceptance counts**:

- Aggregate **52/52 build steps succeeded**; freshly executed **148/148 root unit tests**.
- **84/84 widget-root tests**, including transitive unit tests; do not count all 84 as distinct GUI scenarios or sum overlapping roots as unique coverage.
- **39/39 native workflow checks**.
- **11/11 app group checks**, including the new late giant-line bounded Unicode excerpt workflow.
- **13/13 app recovery checks**, including empty stale journals, >10 MiB rejection/restart, version-2 excerpt/viewport restoration and real save/crash cases.
- **3/3 appearance tests**, also directly re-executed from `.zig-cache/o/c5c2b12be19b7104b8ef98749dc5162d/test` rather than relying only on its cached aggregate result. Headless population: **148 + 3 = 151**.
- Production build passed. Formatting/Python compilation and benchmark build are checked separately.

Logs/reports: `pearl/.cache/coral-m1-resumed-final.log`, `pearl/.cache/coral-native/results.json`, `pearl/.cache/coral-app-groups/results.json`, `pearl/.cache/coral-app-recovery/results.json`, `pearl/.cache/coral-widgets/results.json`.

The old native **TooLarge → NoCheckpoint → unreadable-journal prompt** blocker is **resolved by the recovery/app owner's changes**, not an outstanding blocker in this report. That complete 39-check native run and recovery cases replaced the prior 33-check partial failure. Existing 128 MiB rejection, save/etag/cancellation, source watcher and multi-presentation regressions remain wired. The other agent's `workspace/identity.zig` root import was preserved.

**Latest acceptance is parent-owned.** The parent reports a newer green `test-m1` run after safety fixes and completion of the **40-check UX** review and optional terminal work. Exact latest root/widget/native/group/recovery counts are for the parent to verify; the older counts above must not be presented as final-source counts. This final benchmark/report pass ran only the requested three timing trials, not another test suite or browser review. The help-only prototype check in §7 describes this owner's work, not a claim that no other owner ran UX acceptance.

## 9. Retained history and accepted tradeoffs

**Subsequent user decision:** “i accept the trade off and begin work on m2.” The user accepted retaining the bounded engine policy, the documented timing misses and deferred real input-to-paint qualification for proceeding beyond M0. The checklist below records the choices presented for that decision; it is no longer an unresolved approval request. Raw failures and unverified targets remain unchanged. M2 measurements must not reuse these M0 source hashes as if they identify the newer code.

Historical reports remain in cache for audit; they are not current performance claims:

- `run-g55zto49`: early artificial drain-cap failure.
- `run-ckefkf2w`: externally interrupted 600 s initial command; report left `running` is an interrupted failure, not a pass. Owned orphan benchmark/compositor/bus processes were identified and terminated.
- `run-pz_502u2`, `run-bdsgew3r`: pre-optimization B05 timeouts; superseded by the two supplied optimized runs and the final complete B05 run.
- `run-leu6lqq0`: non-scrollable 100-tab fixture created a 22,238-pixel surface and crashed the compositor; fixed by matching the app's scrollable notebook, not reducing tab count.
- `run-sw20qfbb`, `run-ubmniz1u`, `run-qvb_mkrx`: earlier engine/runner revisions, superseded by current policy measurements. Their raw hashes remain their own identities.
- `run-1vbhk_8d`, `run-0q41qzyp`: historical 1 MiB fallback failures, **superseded** by the safety-fixed 1 MiB supplied reports and final `run-ldrbm59w`; no current incomplete-fallback measurement claim remains.

### Tradeoff checklist presented to the user (subsequently accepted)

1. **Engine decision/tradeoffs:** accept retaining the engine for the bounded foundation with syntax disabled at the documented character/paragraph thresholds and giant lines handled through an explicit excerpt workflow. This is a recommendation backed by functioning native features, not approval granted by the runner.
2. **Original full B03 gate:** full 1 MiB paragraph rendering remains unsupported/guarded in production, with the earlier wrap-off/on **60 s failures** retained. Either keep full rendering as an unmet requirement requiring further work, or explicitly approve the documented bounded-excerpt policy instead. The now-complete **1 MiB / five-cycle / 1,000-sample** fallback is a separately named workload, not a silent replacement for full B03.
3. **Strict proposed timing misses:** final B05 edit p95 **18.186 ms** and retained-source 1 MiB fallback edit p95 **21.474/22.319 ms** exceed 16 ms. Earlier-revision B04 20/100-tab insert p95 **17.431/17.849 ms** also missed that screen. Approve a recorded revised screening budget/deferred performance qualification or require optimization and rerun. These are open performance qualifications, **not absent features or functional M1 incompleteness**; faster obsolete B05 numbers must not replace the final baseline.
4. **Presentation qualification:** require a real injected-event/expected-frame harness for the original paint/startup targets, or explicitly accept deferred qualification. The small GDK frame probe does not satisfy those targets.
5. **Milestone/product signoff:** technical/native regression acceptance is reported green; latest exact counts remain parent-owned. UX40 and optional terminal work are reported complete, not missing feature work. Their completion does not itself approve changes to the original performance gates or policy tradeoffs; those dispositions belong to the user/product reviewer.

**Summary:** retain the engine for the bounded foundation. The final **1 MiB retained-source fallback measurement is complete in both wrap modes**, as is B05. M1 functional completion is not classified as incomplete because proposed performance screens are missed. The user subsequently accepted the timing/syntax/long-line tradeoffs and deferred presentation qualification. Full-render giant-line support is still unsupported, and real injected-input-to-presentation targets remain unverified; neither has been relabelled a passing measurement. No commits or branches were created.
