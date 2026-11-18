# Local semantic search implementation plan

Status: implemented November 16, 2026 (milestones M0–M3 plus CLI, Settings and
docs); real-hardware acceptance and M4 folder watching remain open. Implements
[issue #46](https://github.com/Seafoam-Labs/pearl/issues/46) (local semantic
search in the launcher). Follow-up to the
[launcher assistant](LAUNCHER_AI_IMPLEMENTATION_PLAN.md), which explicitly
deferred semantic file indexing ("Local files … remains a separate feature").
See [ASSISTANT.md](ASSISTANT.md#semantic-search) for implemented behavior.

M0 verification results (2026-11-16): the ggml-org GGUF reports
`general.architecture = "gemma-embedding2"` and mean pooling in its metadata;
revisions pinned below are `6ea3e3a309d12a4779cfda98b8c19800d2d5da71`
(ggml-org) and `031f0d4b35536f69ab3509d4893c923264fcf253` (unsloth). The
runtime gate checks `--embeddings` capability and the architecture string, and
readiness rejects non-finite, zero or wrong-width probe vectors. Delivered:
embedding registry/profiles, `assistant.semantic` config with validation and
migration tests, embedding runtime mode with its own lock, the
`src/search/` module (chunker, bounded store, sandboxed extraction, indexer,
service), launcher document rows with passage snippets and Enter-to-open,
the Assistant Settings section, `pearlctl semantic status|index|stop|delete`,
unit tests in `test-agent`/`test`, and docs. Enabling the feature sets up the
runtime (installing llama.cpp via the package manager when needed) and
downloads the embedding model as one immediate, disclosed operation; the first
index pass then starts automatically once the saved preference has folders and
a model. Open: real-hardware
latency/memory/privacy gates below and code-file support. Folder-change sync
and file watching are implemented in the follow-up
[idle reindex plan](SEMANTIC_IDLE_REINDEX_PLAN.md), which schedules automatic
passes primarily into idle/low-use windows.

Add an opt-in **Semantic search** feature to the Assistant. When enabled, Pearl
indexes user-selected folders with a local **EmbeddingGemma 2** model and the
Super+Space launcher finds documents by description — "the clause about pets in
the lease" returns the lease PDF with the matching passage — without remembering
filenames or exact words. Indexing, embedding and ranking run entirely on the
device. Application search, window switching, the calculator and the existing
Ask Pearl web assistant keep their current behavior and precedence.

## Scope and defaults

| Decision | Initial behavior |
| --- | --- |
| Opt-in | `assistant.semantic.enabled` defaults to false. Fresh installs and older preferences without the field stay disabled. The toggle lives in Settings → Assistant, in its own **Semantic search** section. Turning it on immediately sets up the runtime (installing llama.cpp through the package manager if needed, with terminal confirmation) and downloads the embedding model; both are immediate operations that survive Discard. |
| Independence from chat | Semantic search does not require the chat assistant to be enabled, a chat model download, or any search provider. It shares the assistant's runtime selection and acceleration settings. |
| Disabled footprint | No embedding process, no index directory, no model download, no file reads, no inference on keystrokes. |
| Model | EmbeddingGemma 2 text backbone (270M), GGUF Q8_0 ≈ 310 MB (ggml-org) as the recommended profile; UD-Q4_K_XL ≈ 176 MB (unsloth) as the low-memory alternate. Apache-2.0. Vision/audio `mmproj` encoders are out of scope. |
| Folders | Empty by default. Nothing is indexed without an explicit folder choice. At most 16 folders, absolute paths, verified readable at save time. The first index pass starts automatically once the enabled preference takes effect with folders and a model present; later passes are explicit. |
| File types | UTF-8 text documents (`.txt`, `.md`, `.markdown`, `.rst` and `text/*` sniffed content) and PDF via sandboxed `pdftotext` (Poppler). Scanned PDFs without a text layer are counted and reported, not OCR'd. Code files, images and audio are later work. |
| Network trigger | None for indexing or search. Enabling the feature discloses and starts the model download and, when no compatible runtime exists, a package-manager install of llama.cpp in a user-confirmed terminal transaction. |
| Index storage | `~/.local/share/pearl/search/`, mode 0700, files 0600. Contains document excerpts; never exported, never included in `pearlctl report`, never sent anywhere. |
| Hardware | Preserve the 4 GB non-AI baseline when disabled. Target ≤ 600 MiB additional resident memory with the embedding runtime loaded (Q8_0 weights + context + index cache). CPU-first; the shared acceleration setting may offload to GPU with the existing CPU fallback. |
| Concurrency | The embedding runtime is a second, separately locked `llama-server`. Query embedding may run beside a chat answer; background indexing defers while chat inference is busy. |

## Verified model facts

[EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
([technical report](https://arxiv.org/abs/2610.37364), Apache-2.0) is a
multimodal embedding model: 740M total parameters combining a 270M text
backbone with modular vision (170M) and audio (300M) encoders. Pearl loads the
text backbone only.

- Output: one unified **768-dimensional** vector, mean pooling, 512→768
  projection. **8,192-token** context. 100+ languages and improved code
  understanding.
- **Matryoshka (MRL)** truncation to 512/256/128 dimensions. Quality is close to
  lossless down to 256d (MTEB multilingual 60.41 vs 61.36 at 768d). Truncated
  vectors **must be L2-renormalized**; skipping this silently degrades ranking.
  Queries and documents must share a dimension.
- **Task prefixes** (text only): retrieval queries use
  `task: search result | query: {query}`; documents use
  `title: {title} | text: {content}` with `title: none` when untitled. Pearl
  uses the filename stem as the title. Omitting prefixes reduces precision.
- **Precision warning:** the model card forbids float16 inference (NaN or
  silently degraded embeddings). Q8_0/BF16 GGUF weights with llama.cpp's
  float32 compute avoid this; the readiness probe additionally rejects
  non-finite or zero vectors.
- llama.cpp supports the architecture: current upstream
  `tests/test-model-resolution.cpp` resolves the exact ggml-org GGUF filenames
  below. Repository-selected runtimes must still pass an explicit capability
  check (`--embeddings`, working `/v1/embeddings`); older releases are rejected
  with an actionable error, never a silent fallback.

Managed download candidates (sizes and LFS SHA256 verified 2026-11-16; the
immutable repository revision must be captured at M0 per registry convention):

| Profile | Repository | File | Bytes | SHA256 |
| --- | --- | --- | --- | --- |
| `embeddinggemma-2-q8_0` (recommended) | `ggml-org/embeddinggemma-2-GGUF` | `embeddinggemma-2-Q8_0.gguf` | 309,855,456 | `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135` |
| `embeddinggemma-2-ud-q4_k_xl` (low memory) | `unsloth/embeddinggemma-2-GGUF` | `embeddinggemma-2-UD-Q4_K_XL.gguf` | 175,673,856 | `ea905fd08e8061db77a0031cbb5096d459d7cfd2bdd0ad2ba66e483f16719493` |

Both repositories also publish BF16/F16 weights and separate `mmproj-*`
multimodal projectors; Pearl does not download those in v1. License links point
at the Apache-2.0 text in each repository, following the existing
`model_registry.zig` license-link convention.

## User interaction

### Enable and prepare (Settings → Assistant → Semantic search)

A new `layout.Section` sibling to Model / Runtime & acceleration / Search
engines / Resources & behavior in [`assistant_view.zig`](../src/settings/assistant_view.zig):

- **Enable semantic search** switch, default off, participating in the normal
  draft / Apply & save / Discard workflow. Disclosure beside it: "Turning this
  on sets up llama.cpp if needed (a terminal opens for package-manager
  confirmation) and downloads the embedding model. Setup is immediate and
  survives Discard. Indexing and search run on this device; nothing is
  uploaded."
- **Embedding model** row: name, quantization, download size, publisher and
  license link; **Download**, **Verify**, **Remove** actions with progress,
  cancellation and error states, reusing the chat model management machinery
  (`downloads.zig`). Download completion never enables the feature by itself.
- **Indexed folders** list: **Add folder** (native GTK folder chooser), per-row
  **Remove**. Empty state explains that nothing is indexed until a folder is
  added. Removing a folder drops its entries from the index on the next pass.
- **Index status** row: `Not indexed` / `Indexing… 42% (128/305 files)` /
  `Ready · 1,234 passages from 89 files · updated 2 minutes ago` /
  `Paused (assistant is answering)` / error states with reasons. Actions:
  **Index now**, **Stop**, **Delete index**.
- **Runtime note**: semantic search uses the runtime and acceleration selected
  above. A capability failure ("This llama-server build does not support
  embeddings") points at Runtime setup, exactly like chat runtime errors.
- **Poppler note** when `pdftotext` is unavailable: "PDF indexing requires
  Poppler (pdftotext). Text documents are still indexed." Mirrors the existing
  preview `missing_pdf` wording; no package transaction is started implicitly.

Enabling saves the preference and immediately starts setup as an explicit,
cancellable operation: reuse a compatible runtime or install llama.cpp through
the package manager (terminal-owned transaction, never killed by Settings),
then download the embedding model if it is not already installed. Setup
requires `--embeddings` capability before and after installing. **Set up now
(runtime and model)** retries; the manual Download/Verify/Remove actions
remain. Enabling alone starts no index; the first pass starts automatically
once the enabled preference takes effect (Apply & save) with folders
configured and the model installed, or right after setup completes when the
preference was already saved. An existing index is never rebuilt implicitly.
Readiness
requires: enabled + verified embedding model + at least one folder + a
completed index pass. Disabling and Applying cancels queries and indexing,
unloads the embedding runtime and keeps the index on disk (re-enable is cheap);
**Delete index** is the separate, explicit removal action. **Remove** of the
embedding model follows the chat convention: disable/stop first, then remove.

### Search from the launcher

The search field is unchanged. With semantic search ready, results arrive in
two stages:

1. **Instant stage (unchanged):** calculator, application and window hits rank
   exactly as today in `rankJob`. Typing never waits on a model.
2. **Semantic stage (new):** after a 200 ms edit debounce, queries of ≥ 3
   trimmed bytes are embedded locally and scored against the index. Up to four
   **document rows** merge into the list when ready, each showing the filename,
   its folder, and the best matching passage as the detail line, e.g.
   `lease-agreement.pdf · Documents · "…Tenant may keep up to two pets…" · Enter to open`.

Precedence and guards:

- Calculator results and exact application/window matches stay on top. Document
  scores occupy a band below application substring matches (400) and above the
  implicit Ask Pearl row (−1000); proposed mapping `120…390` from cosine
  similarity, calibrated on the fixture corpus at M3. A leading `?` still
  forces Ask Pearl; `=` still forces the calculator.
- One row per file (best passage wins), cosine floor ≈ 0.30 (calibrated, not a
  published constant), at most four rows. Empty queries show no document rows.
- Every semantic result carries the edit revision, generation and session ID it
  was computed for; stale results are discarded exactly like existing jobs.
  New edits, launcher dismissal, lock and session loss cancel in-flight work.
- **Enter** opens the file with its default application via GIO
  (`AppInfo.launchDefaultForUri` on a `file://` URI, launch context/timestamp
  conventions as in `launcher.open`). The path is re-stat'ed at activation;
  vanished files return `StaleResult` and trigger an index refresh, never a
  launch. Row icons come from the GIO content-type icon, with a generic
  document fallback. IME composition, arrow-key selection and fresh-row Enter
  checks are preserved.
- Cold start: the first query after idle loads the embedding runtime
  asynchronously (target ≤ 5 s). Rows simply appear when ready; no spinner row,
  no error while typing. Not-installed / not-indexed states are silent in the
  launcher and actionable in Settings.
- Warm latency target: ≤ 300 ms p95 from debounce fire to visible rows on the
  reference CPU (release gate, not a completed measurement).

### Privacy and lifecycle

- All indexing, embedding and ranking are local. No query, passage, filename or
  vector leaves the device. The model download is the only network action and
  is explicit, resumable and hash-verified like chat models.
- The index stores document excerpts (≤ 2 KiB per passage). Directory 0700,
  files 0600, excluded from preference exports, the raw JSON editor, backups
  and `pearlctl report`. Folder paths themselves are ordinary preferences, like
  `custom_model` paths.
- Lock screen / inactive session: cancel queries and indexing, unload the
  embedding runtime (same policy as the agent host's `setLocked`). Unlock
  restores on-demand query loading; no automatic reindex.
- Shell shutdown kills the embedding child (existing `PDEATHSIG` child setup).
  Loss of the verified session stops everything.

## Preference shape

Nested under the existing `assistant` object in
[`preferences.zig`](../src/config/preferences.zig); illustrative, not an
implemented schema:

```json
{
  "assistant": {
    "enabled": false,
    "semantic": {
      "enabled": false,
      "model_id": "embeddinggemma-2-q8_0",
      "folders": ["/home/zoey/Documents"]
    }
  }
}
```

Validation (in `agent/config.zig`, alongside the existing assistant checks):

- `model_id` must resolve in the embedding registry (never the chat registry,
  and vice versa); `custom` embedding GGUFs are out of scope for v1.
- `folders`: ≤ 16 entries, each an absolute path ≤ 4096 bytes, no duplicates,
  no NUL/control characters, UTF-8 valid. Existence/readability is checked at
  save time with a concrete per-folder error; a folder that disappears later
  is reported in index status, not a validation failure.
- Fixed v1 constants (not preferences, to avoid mixed-index states): 256 MRL
  dimensions, chunker version, chunk target ≈ 450 tokens with ≈ 64-token
  overlap, 20 MiB per-file cap, 50,000-file / 200,000-chunk caps, 120 s idle
  unload, skip hidden entries and directory symlinks, fixed exclude directory
  names (`.git`, `.cache`, `node_modules`, …).
- Absent `semantic` parses to the disabled default; add an explicit migration
  test mirroring the assistant-runtime migration tests. The generic three-way
  merge in `config/merge.zig` handles the new object; the folder list merges
  atomically like `providers`. Add round-trip and conflict tests.
- Index state (counts, timestamps, model identity) lives in the index manifest,
  never in preferences.

## Architecture

All new implementation is Zig (project policy). The only external boundaries
are the already-established ones: the user-selected `llama-server` for
inference and sandboxed Poppler `pdftotext` for PDF extraction.

### Embedding runtime (reuse, not a new stack)

Extend [`agent/runtime.zig`](../src/agent/runtime.zig) with a
`mode: enum { chat, embedding }` (default `.chat`, existing behavior
byte-for-byte unchanged):

- Shared: executable resolution/fingerprinting, authenticated loopback with a
  0600 per-session key file, dynamic port reservation, `PDEATHSIG`/nice/core
  child setup, memory monitoring, telemetry hooks, CPU fallback and GPU device
  selection via `compute.zig`.
- Embedding-specific launch: `--embeddings`; no `--jinja`, no
  `--reasoning-format`, no chat tool checks; `--ctx-size 2048` (chunks are ≤
  ~512 tokens plus prefix); larger batches for indexing throughput
  (`--batch-size 2048 --ubatch-size 512`, capability-gated); `--parallel 1`.
  Pooling: verify at M0 whether the GGUF metadata supplies mean pooling or
  `--pooling mean` must be passed explicitly.
- Separate exclusive lock `pearl-embedding-runtime.lock` in the user runtime
  dir, so chat and embedding servers can coexist; each remains single-instance.
  Before launch, require available system memory ≥ weights + context allowance
  + 512 MiB headroom (reuse `memory.availableMiB()`), otherwise report a
  memory-pressure error instead of swapping the desktop.
- Readiness: `/v1/models` alias check, unauthenticated-request rejection check,
  then a probe `POST /v1/embeddings` whose result must be 768 finite,
  non-zero floats. This replaces `model_check.zig`'s chat/tool smoke checks and
  catches the model card's silent-NaN failure class.
- Capability gate: `runtime_probe.required()` plus `--embeddings` for embedding
  mode; `gguf.zig` gains bounded reads of `general.architecture` and embedding
  metadata to reject chat models in the embedding slot (and embedding models
  in the chat slot) before launch.
- Idle unload after 120 s without queries or indexing. Indexing jobs check the
  shell's view of `agent.compute.busy` and defer while a chat answer runs;
  query embedding is small and may run concurrently.

### Index store and indexer (new `src/search/` module)

Pure Zig, shell-owned, bounded and cancellable:

- `store.zig` — on-disk index under `~/.local/share/pearl/search/`:
  `manifest.json` (schema version, model id + SHA256, dimension, chunker
  version, folder snapshot, counters, updated time), `vectors.bin` (f32 LE,
  L2-normalized 256d MRL-truncated vectors) and bounded chunk records
  (path, mtime_ns, size, chunk ordinal, passage ≤ 2 KiB). Loads enforce caps
  and reject corrupt/truncated files with a rebuild prompt, never a shell
  crash (bounded-decoder style of the Aqueous model). Writes commit atomically
  via temp directory + rename; incremental passes append and compact.
  A model/dimension/chunker change invalidates the index and requires an
  explicit reindex.
- `chunk.zig` — UTF-8-safe paragraph/sentence-aware chunking, ≈ 450-token
  target with ≈ 64-token overlap, filename-stem title, deterministic output.
  Token counts calibrated against the runtime's `/tokenize` at M0; a
  char-budget approximation with tokenizer verification for outliers keeps
  indexing round-trips bounded.
- `extract.zig` — text files read natively with UTF-8 validation and the
  20 MiB cap. PDFs go through a bounded `pdftotext -enc UTF-8 -nopgbrk` child
  in the existing bwrap sandbox pattern from
  [`preview_runner.zig`](../src/files/preview/platform/preview_runner.zig)
  (`--unshare-all`, `--die-with-parent`, `--cap-drop ALL`, read-only `/usr`,
  single source bind, bounded pipes, child reaping, 30 s timeout, ≤ 8 MiB
  output). Reuse the runner via a shared module where build boundaries allow;
  otherwise mirror its fixed argv and bounds. Poppler capability detection
  follows `preview_providers.zig`. Extraction never runs in the shell process.
- `indexer.zig` — single background worker (`gio.Task` thread + cancellable):
  walk selected folders (no symlink following, hidden/exclude skipping),
  compare `(mtime_ns, size)` per file, re-embed only new/changed files,
  tombstone deletions, update counters/progress for Settings. Throttled and
  nice'd; pauses on memory pressure and while chat is busy; resumable after
  cancel. **Index now** runs a full incremental pass; Stop cancels cleanly.
- `service.zig` — the shell-facing owner: holds config, store, runtime and
  worker; exposes `query(text, cancel) → []DocumentHit` (embed with the query
  prefix, truncate + renormalize, brute-force cosine over normalized vectors,
  per-file dedupe, threshold, top 4) plus status/progress for Settings and
  `pearlctl`. Brute force is deliberate: at the 200k-chunk cap and 256d, a scan
  is tens of millions of multiply-adds — single-digit milliseconds in Zig,
  with no ANN dependency. Revisit only if the cap proves limiting.

### Shell and launcher wiring

- [`ui/surfaces/manager.zig`](../src/ui/surfaces/manager.zig) owns a
  `search.Service` beside the existing `agent: Host`; preference changes
  reconfigure it, lock/session events suspend it, shutdown stops it. The agent
  protocol (`agent/protocol.zig`) is unchanged — semantic search is not routed
  through `pearl-agent`, whose lifecycle is tied to the chat window. (Running
  inference checks in a non-agent process already has precedent: the Settings
  app launches `Runtime` in-process for runtime/model checks.)
- [`desktop/launcher.zig`](../src/desktop/launcher.zig): add `.document` to
  `Hit.kind`; keep `rankJob` pure and instant; merge semantic hits in a second
  async stage guarded by the existing generation/session/edit-revision
  machinery; extend `open` with the document branch. `configureAssistant`
  gains the semantic readiness/query callback (or a sibling
  `configureSemantic`) so the launcher never imports the service directly.
- `pearlctl`: `semantic status | index | clear` commands and a
  `semantic_status` manager op, following the existing `assistant_*` ops.
- i18n: every new user-visible string marked in the `pearl` domain; launcher
  and settings rows follow existing accessibility semantics (focusable rows,
  readable detail text, Enter/arrow behavior, IME preserved).

## Integration contracts (touch points)

| Area | Files | Change |
| --- | --- | --- |
| Registry | `src/agent/model_registry.zig` | New `embedding_models` array + `findEmbedding`; same `Model` shape so `downloads.zig` works unchanged; chat `models`/`selection` untouched |
| Config | `src/agent/config.zig`, `src/config/preferences.zig` | `Semantic` struct, validation, defaults, migration + merge tests |
| Runtime | `src/agent/runtime.zig`, `runtime_probe.zig`, `gguf.zig` | Embedding mode, capability gate, architecture metadata, second lock |
| Search core | `src/search/{store,chunk,extract,indexer,service}.zig` (new) | Index, extraction, ranking; pure Zig + bounded sandboxed PDF child |
| Settings | `src/settings/assistant_view.zig`, `assistant_layout.zig` | Semantic section: switch, model actions, folder list, index status/actions |
| Launcher | `src/desktop/launcher.zig`, `src/ui/surfaces/manager.zig` | `.document` hits, async merge, open-by-URI, service ownership, lock wiring |
| CLI | `src/cli/pearlctl.zig`, `src/cli/options.zig`, manager op dispatch | `semantic` commands/status |
| Build/tests | `build.zig`, `src/tests.zig`, `tests/fixtures/` | New module test targets; semantic fixture corpus; no new executable, no llama.cpp build in normal Pearl builds |
| Docs/i18n | `docs/ASSISTANT.md`, `docs/DESKTOP.md`, `README.md`, `translations/` | Implemented behavior, launcher docs, string extraction |

Packaging: Poppler becomes an optional dependency note (PDF indexing only);
the assistant runtime recipe/pin may need a bump to a release with
EmbeddingGemma 2 support — recorded as an explicit packaging change, never a
silent runtime requirement change. Devario installation continues through
Shelly; no `pacman` assumptions in new code paths.

## Milestones

- **M0 — Pins and capability proof.** Capture immutable HF revisions for both
  GGUF profiles; re-verify bytes/SHA256; confirm `llama-server --embeddings`
  request/response shape, pooling source, architecture metadata key and
  minimum capable llama.cpp release on Devario's repository version; calibrate
  chunk token budget and cosine threshold on a small fixture corpus (including
  a lease-style PDF mirroring the issue's demo). Deliverables: registry
  entries, probe gate, spike notes under `spikes/`.
- **M1 — Settings and model management.** Config schema + validation +
  migration/merge tests; Assistant page section with switch, model
  download/verify/remove, folder chooser/list, status placeholders. Enabling
  triggers runtime setup (embedding-capable `ensureEmbedding`) plus the model
  download as one immediate operation. No search yet; disabled footprint
  verified.
- **M2 — Indexer and store.** Embedding runtime mode; walk/extract/chunk/embed
  pipeline; atomic store; Index now / Stop / Delete index; automatic first
  pass when applied enablement meets folders + model readiness; incremental
  mtime/size passes; caps, cancellation, memory guards; sandboxed `pdftotext`
  with Poppler-missing and scanned-PDF states.
- **M3 — Launcher search.** Debounced query path, document rows with passages,
  precedence band, Enter-to-open with stale guards, lock/suspend, test-hook
  stub embeddings for deterministic UI tests. Acceptance: the issue's demo
  query finds the fixture lease PDF and shows the pets passage.
- **M4 — Hardening and operations.** `pearlctl semantic`; docs and
  translations; benchmark and real-hardware acceptance; packaging notes.
  Folder-change sync and debounced file watching moved to the
  [idle reindex plan](SEMANTIC_IDLE_REINDEX_PLAN.md) (automatic passes run
  primarily when the computer is idle or in low use).

## Validation and acceptance

Unit/fixture tests (private fixtures per [TESTING.md](TESTING.md), no real
models or network in default suites):

- Chunker: boundaries, overlap, UTF-8 safety, determinism, oversized inputs.
- Store: round-trip, atomic commit, corruption/truncation rejection, cap
  enforcement, model/dimension/chunker invalidation, tombstones.
- Ranking: MRL truncation **with renormalization**, cosine ordering, per-file
  dedupe, threshold, score band vs `policy.score` and `intent.score`
  (calculator/exact apps/`?` always win).
- Config: folder validation, registry separation (chat IDs rejected for
  embeddings and vice versa), absent-field migration, draft merge conflicts.
- Launcher: two-stage merge, stale-revision discard, cancel-on-edit/dismiss,
  Enter opens only fresh rows, vanished-file `StaleResult`, IME preserved —
  using deterministic stub embeddings via existing test-hook patterns.
- Extraction: sandbox bounds, timeout, output cap, invalid UTF-8, missing
  Poppler, empty/scanned PDF.

Real-hardware release gates (per [RELEASE.md](RELEASE.md), pending until run):

- Disabled footprint: no process, directory, download or inference.
- Demo acceptance: "the clause about pets in the lease" → lease PDF + passage.
- Warm query→rows ≤ 300 ms p95; cold load ≤ 5 s; typing latency unchanged.
- ≤ 600 MiB added resident memory with Q8_0 loaded; 4 GB baseline intact.
- Zero network traffic during indexing/search (download-only evidence).
- Lock/unlock, disable-Apply, folder removal, Delete index, model remove,
  old-runtime capability error, corrupt-index recovery, cap behavior on a
  large folder, concurrent chat answer + search.
- Draft/Apply/Discard and external-edit merging; exports/reports exclude index
  state; accessibility pass on new rows and settings controls.

## Risks and open questions

- **Runtime availability:** repository `llama-cpp` may lag the architecture.
  Mitigation: explicit capability gate with setup guidance; packaging pin bump
  recorded at M0; no version allowlist in application code (existing probe
  philosophy).
- **Silent embedding degradation:** fp16 NaN class and MRL renormalization
  mistakes produce plausible-but-wrong rankings. Mitigation: Q8_0/BF16 weights,
  finite-vector readiness probe, renormalization unit tests, fixture ranking
  regression.
- **PDF quality:** scanned/encrypted PDFs yield no text; complex layouts yield
  noisy passages. Mitigation: counted/reportable skips, passage preview in the
  row so users see what matched; OCR explicitly out of scope.
- **Scale:** brute force is bounded by the 200k-chunk cap; beyond that, an ANN
  structure is future work, not a v1 dependency.
- **Privacy of excerpts:** the index is a sensitive local artifact. Mitigation:
  0700/0600, explicit consent per folder, Delete index, exclusion from
  exports/reports, no telemetry of content.
- **Memory contention with chat:** two servers can coexist. Mitigation: memory
  guard before launch, indexing defers while chat is busy, 120 s idle unload.
- Open: default cosine floor and score band (calibrate M0/M3); whether code
  files join v1.1 (model is strong at code, but scope stays documents-first);
  whether a 768d "maximum quality" index option is worth the reindex complexity
  (deferred); folder-watch granularity, rate limits and idle scheduling are
  specified in the [idle reindex plan](SEMANTIC_IDLE_REINDEX_PLAN.md).

## References

- [Issue #46](https://github.com/Seafoam-Labs/pearl/issues/46) and the
  [demo video](https://github.com/user-attachments/assets/ea94da38-5d25-4531-8fc9-942f4c4a38f7)
  shared by [@ngxson](https://x.com/ngxson/status/2109044337367540102).
- [EmbeddingGemma 2 model card](https://huggingface.co/google/embeddinggemma-2) ·
  [ggml-org GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF) ·
  [unsloth GGUF](https://huggingface.co/unsloth/embeddinggemma-2-GGUF) ·
  [technical report](https://arxiv.org/abs/2610.37364).
- [Launcher assistant plan](LAUNCHER_AI_IMPLEMENTATION_PLAN.md) ·
  [Assistant behavior](ASSISTANT.md) ·
  [GPU/runtime plan](ASSISTANT_GPU_RUNTIME_PLAN.md) ·
  [Model benchmark plan](ASSISTANT_MODEL_BENCHMARK_PLAN.md).
