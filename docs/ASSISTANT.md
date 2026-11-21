# Launcher assistant

The [GPU and runtime update](ASSISTANT_GPU_RUNTIME_PLAN.md) adds selectable
mistral.rs installations and experimental Vulkan/CUDA execution. See the
[interaction mockups](mockups/assistant-gpu/README.md) and
[validation evidence](../artifacts/assistant/gpu-runtime/README.md).

Pearl's experimental assistant is opt-in and disabled by default. In Settings →
Assistant, choose a local model, explicitly download it, enable the assistant
and Apply. Bing search works without provider setup. Type a question in Super+Space and
activate **Ask Pearl**. Pearl opens a
separate native chat window. It can answer directly on device or request web
search from the selected engine(s). Typing does not start a model or make a
network request. Submitting a question no longer forces a search.

## Conversation and optional tools

Ordinary chat, explanations, writing, and coding help do not require sources or
an enabled search provider. Responses stream even without search results. Search
is model-selected, guided by the system prompt to use it for current information,
verification, or explicit requests, not routine conversation. A model can still
make mistakes about when to search.

A successful search/page read in the current turn requires source references in
the resulting answer. Unknown source IDs trigger one tools-disabled correction;
failed correction is labeled incomplete. Prior sources do not force citations on
an unrelated follow-up such as “thanks.” Citation checks validate IDs and syntax,
not factual truth or whether a source supports every claim. Source links remain
host-owned. Tool errors, denied page reads, and empty searches are returned to the
model as structured results so it can explain the limitation instead of inventing
results. Cancellation still stops work rather than becoming a recoverable tool
failure.

Questions accept up to **32 KiB of UTF-8 text**. Recent questions and answers are
kept whole within the context budget rather than clipped to fixed byte prefixes.
Pearl uses the runtime's `/apply-template` and `/tokenize` endpoints to measure
messages, tool schemas, and the assistant prefix, reserving the configured
completion allowance plus a safety margin. Oldest complete turns are removed
first, then optional previous evidence; the current question and active tool
call/result groups are never clipped. A request that still cannot fit fails
explicitly. The UI retains at most 20 turns and 128 KiB per conversation.

Completed, incomplete, cancelled, and failed responses have distinct outcomes;
a truncated draft is not presented as complete. Runtime/model combinations that
pass ordinary chat but fail tool qualification remain usable in **chat-only**
mode, with a visible warning and no tool execution. Settings reports chat and
web-tool compatibility separately. Authentication and runtime isolation checks
remain mandatory.

Phase 1 of the [conversational assistant and local tools plan](ASSISTANT_CHAT_TOOLS_IMPLEMENTATION_PLAN.md)
is implemented. Filesystem permissions, file creation/deletion, explicit deletion
confirmation, and requested application launching remain planned; **no local tools
are enabled by this change**.

## Bing and other engines

The initial provider is **Bing RSS**, using Bing's public HTTPS search feed.
No API key, account or server URL is required. Pearl sends the model's query,
language and safe-search preference only when you ask or test the connection.
The feed is a best-effort integration, not Microsoft's retired Search API;
network failures and invalid responses are reported without switching providers.
**Test connection now** sends the disclosed sample query “Pearl desktop”.
The local model must still be downloaded and its runtime installed.

Google through SearXNG, general SearXNG, Brave Search API, and Google's existing-account JSON API are
also available. Default mode uses one engine; all-enabled mode accepts at most
three. Existing configured providers are preserved. Google through SearXNG
requires your instance URL with its Google engine and JSON output enabled;
Pearl sends `engines=google`. Google JSON API needs
an API key and search engine ID; it is closed to new customers and retires
January 1, 2027. [Google's lifecycle notice](https://developers.google.com/custom-search/v1/overview).

API keys are stored in Secret Service using libsecret, separately from exported
preferences. The session collection is available for temporary keys. An absent
or locked Secret Service reports an error and never falls back to plaintext.
The explicitly configured SearXNG endpoint may use private HTTP; public result
pages require HTTPS and their resolved addresses cannot be private networks.

## Local models and runtime

The model selector includes these managed GGUF downloads:

| Model | Quantization | Download |
| --- | --- | --- |
| LFM3-1.7B | Q4_K_M / Q5_K_M / Q8_0 | 1.10 GB / 1.26 GB / 1.85 GB |
| Qwen3-4B-Instruct-2507 | Q4_K_M | 2.50 GB |

Each entry has its own immutable repository revision, exact byte count, SHA256
and license link in [`model_registry.zig`](../src/agent/model_registry.zig).
Interrupted downloads resume from `.part` files against that revision; the
complete hash must match before atomic installation. Custom local GGUFs have no
Pearl file-size ceiling and are checked for chat health and optional tool-call
compatibility before use.
Models are not bundled with Pearl. Model/runtime tests use
draft settings and local fixtures. Stop a current answer before testing; Pearl
unloads an idle runtime first and an exclusive session lock prevents a second
inference process. Disable and Apply before removing a managed download.

CPU threads default to **0 = runtime automatic**; a positive count is passed
through without a Pearl CPU-count cap. Saved explicit counts remain unchanged.
Context and generation tokens also accept **0 = model profile** or an explicit
value. Selecting a different model resets those two fields to automatic in the
draft. Existing saved token settings remain explicit until changed. Context must
leave room for generation and prompt overhead; the selected runtime/model still
determines which context sizes work.

The LFM3-1.7B profile uses 32,768 context tokens and 4,096 generation tokens,
including reasoning. It requires `--reasoning-format` support; Pearl requests
separate reasoning fields and displays only the final answer. The two new
Instruct profiles use 4,096 context tokens and 512 generation tokens. Larger
profiles have longer inference deadlines. These are editable defaults, not
performance rankings. **Compare suggested models** measures the models on your
computer; the [implementation plan](ASSISTANT_MODEL_BENCHMARK_PLAN.md) records
the design and remaining hardware qualification.

Build the frontend normally, or by itself:

```sh
zig build build-shell build-agent build-settings
```

Choose **Runtime & acceleration** in Assistant settings:

- **Set up runtime (install if needed)** checks the chosen runtime, then existing
  system/private runtimes. It reuses one with the required capabilities. Otherwise
  it opens a terminal to install `mistralrs` using `shelly install standard
  --needed` on Devario, or `sudo pacman -S --needed` on Arch and Arch derivatives.
  GPU setup adds `ggml-vulkan` for Automatic/Vulkan or `ggml-cuda` for CUDA;
  CPU setup needs only `mistralrs`. GPU backends are bundled.
  These are repository-selected versions, not a hard-coded release. See the
  [Arch runtime package](https://archlinux.org/packages/extra/x86_64/mistralrs/)
  and [backend packages](https://docs.mistralrs.dev).
  Devario is detected before Arch ancestry and always uses Shelly.
  The package manager handles authentication, transaction confirmation, signatures
  and dependencies. No AUR builds, repositories, forced downgrades, database-only
  refreshes or system-wide upgrades are started by Pearl.
  Setup requires foot, Ghostty (included with Devario), kitty, alacritty, konsole
  or xterm; Arch also needs sudo.
  Complete the terminal prompts, then Pearl rechecks capabilities and selects the
  runtime in the settings draft. **Apply** saves that selection; **Check runtime
  and model now** verifies the model, authentication and tools. Installing a GPU
  backend does not install a driver or guarantee a usable GPU.
  Package installations take effect immediately and survive Discard. Closing
  Settings does not kill an active package transaction. Failed/cancelled installs
  or an incompatible repository version leave the runtime selection unchanged;
  fix the package-manager error or update the repository and retry setup.
- **System installation** searches `/usr/bin/mistralrs`, then
  `/usr/local/bin/mistralrs`, and resolves the actual executable.
- **Pearl runtime package** uses the private optional installation.
- **Custom executable** accepts an absolute path or file chooser selection.
  Paths with spaces work; shell commands and extra arguments are not accepted.

Fresh preferences use System + CPU. Existing assistant preferences without a
runtime field migrate to Pearl runtime package + CPU. No exact upstream version,
commit, checksum or `runtime.json` is required by the application. Switching
runtime never changes the model or search engine. Runtime installation is an
explicit setup action; opening Settings or submitting a question does not start
a package transaction. Missing-runtime errors point to setup. Unsupported
distributions retain manual system/custom runtime selection.

**Discover runtime and GPU devices** reads version/help/device information.
**Check runtime and model now** additionally tests authentication, token counting,
streaming and tool/result continuation with the selected model. Tests make no web
searches. Failed optional tool checks fall back to chat-only mode only after a
fresh chat probe succeeds. Required capabilities must pass even for an unlisted release. Changed
executable/model metadata invalidates a loaded profile; full checks run on each
new load. There is no persistent compatibility cache across driver/library
updates. Runtime changes during a check are rejected.

Build the optional inference runtime from an explicitly selected source:

```sh
zig build build-assistant-runtime \
  -Dassistant-runtime-source=/path/to/mistral.rs \
  -Dassistant-runtime-backend=vulkan
# Or verify a caller-selected source archive:
zig build build-assistant-runtime \
  -Dassistant-runtime-archive=/path/to/llama.tar.gz \
  -Dassistant-runtime-sha256=EXPECTED_SHA256 \
  -Dassistant-runtime-backend=cpu
```

Backend choices are `cpu`, `vulkan` and `cuda`. The target stages actual build
libraries and SONAME files under `zig-out/libexec/pearl/assistant` with `$ORIGIN`
lookup. Optional provenance records the source kind, archive hash and backend;
it does not restrict which runtime the app accepts. Normal Pearl builds do not
build or download mistral.rs. Upstream Cargo and the requested GPU development
dependencies must already be available.

The optional [distribution recipe](../packaging/assistant/PKGBUILD) keeps its
own reproducible release/checksum independently of Pearl. It defaults to CPU;
`PEARL_ASSISTANT_BACKEND=vulkan makepkg` or `PEARL_ASSISTANT_BACKEND=cuda makepkg`
builds the corresponding alternative package. A system/custom runtime can be
used without that package. Model download integrity checks remain mandatory.

## Semantic search

Semantic search is a separate opt-in feature in Settings → Assistant →
**Semantic search**, disabled on fresh installs and when older preferences omit
the field. It does not require the chat assistant to be enabled, a chat model
or any search provider. When enabled and indexed, the Super+Space launcher
finds documents by description and shows the matching passage; Enter opens the
file with its default application. See
[DESKTOP.md](DESKTOP.md#semantic-document-search) for launcher behavior and the
[implementation plan](SEMANTIC_SEARCH_IMPLEMENTATION_PLAN.md) for architecture.

Turning the switch on immediately sets the feature up: it reuses a compatible
installed runtime or installs mistral.rs through the distribution package
manager (a terminal opens for authentication and confirmation), then downloads
the embedding model. Both are immediate operations that survive Discard, with
progress, cancellation of the download phase, and clear errors;
**Set up now (runtime and model)** retries them. The package manager owns its
transaction — Pearl never kills it, and closing Settings does not stop it.
Setup verifies the runtime supports `--embeddings` before and after installing;
a repository release without embedding support is reported, not used.

The embedding model is **EmbeddingGemma 2** (Google DeepMind, Apache-2.0), text
backbone only. Two managed profiles are pinned with immutable revisions, exact
byte counts and SHA256 in [`model_registry.zig`](../src/agent/model_registry.zig):
`ggml-org/embeddinggemma-2-GGUF` Q8_0 (310 MB, recommended) and
`unsloth/embeddinggemma-2-GGUF` UD-Q4_K_XL (176 MB, low memory). The multimodal
`mmproj` projectors are not downloaded. Downloads reuse the chat model
machinery: resumable and hash-verified before atomic installation; an already
installed model is not downloaded again.

Nothing is indexed until you add folders (at most 16, absolute paths). The
first index pass is scheduled automatically once enabling takes effect with
folders configured and the model installed — it runs in the first quiet
window (below), not immediately. An existing index is never rebuilt
implicitly; **Index now** re-runs a pass on demand, immediately. Indexing walks
selected folders without following symlinks,
skips hidden entries and common cache directories, and indexes UTF-8 text
documents (`.txt`, `.md`, `.markdown`, `.rst`) natively and PDFs through a
bubblewrap-sandboxed `pdftotext` child. PDF indexing requires Poppler; without
it, text documents still index and the status says so. Scanned PDFs without a
text layer are counted as skipped, never OCR'd. Files are capped at 20 MiB;
the index at 50,000 files / 200,000 passages. Changed files are re-embedded by
mtime/size; deleted files and removed folders drop out on the next pass.

The index lives in `~/.local/share/pearl/search/` (0700, files 0600): a manifest,
normalized 256-dimension Matryoshka vectors and passage records. It contains
document excerpts, stays on the device, and is excluded from preference
exports, the raw JSON editor and `pearlctl report`. **Delete index** removes it;
disabling the feature keeps it for cheap re-enable. A model or chunker change
invalidates the index and requires an explicit reindex.

Semantic search reuses the runtime and acceleration selected for the assistant.
The embedding server is a second, separately locked `mistralrs` started with
`--embeddings` and mean pooling; runtimes without embedding support are
rejected with an actionable error. Readiness verifies a probe embedding is
768 finite, non-zero values before any document is indexed. The runtime unloads
after 120 idle seconds; indexing defers while a chat answer is running and
yields to live launcher queries. Lock screen and session loss cancel work and
unload the runtime. All indexing, embedding and ranking are local — the model
download is the only network operation.

`pearlctl semantic status|index|stop|delete` exposes the same controls; Settings
uses that verified channel because the shell owns the index.

**Background indexing** (Settings → Assistant → Semantic search) keeps the
index fresh without manual passes, primarily when the computer is idle or in
low use. The choice is `Idle or low use` (default), `Idle only` or `Manual
only`. Automatic work runs in bounded bursts — 120 s in idle windows (180 s of
no input, via the compositor's ext-idle-notify, which honors idle inhibitors
so video and games block it) and 15 s in low-use windows (confirmed low CPU
load, no typing, AC power). Bursts stop promptly when you return, keep their
committed progress (searchable immediately) and reschedule; at least five
minutes separate automatic passes, and the first window opens no earlier than
two minutes after login. On battery, only idle windows run, and only while
charging or at ≥ 50%; power-saver mode defers everything. Locked sessions
never index. Compositors without idle notifications degrade to low-use-only
mode, disclosed in status.

Freshness sources: directory monitors (folder roots plus discovered
subdirectories, capped at 256) mark changed paths dirty; a stat-only rescan at
most every six hours covers anything monitors miss (network mounts, inotify
limits), with degraded mode reported honestly. Removing a folder applies
immediately as a metadata-only commit — no runtime or window needed. Adding a
folder queues an incremental pass for the next quiet window. Switching the
embedding model queues a full rebuild the same way. The status line shows
pending changes and what the scheduler is waiting for. Code-file support and
real-hardware latency/memory acceptance remain open gates in the
[idle reindex plan](SEMANTIC_IDLE_REINDEX_PLAN.md).

## GPU execution and recovery

CPU is the default. **Automatic** chooses one available supported device with
sufficient reported memory, otherwise CPU. **Selected GPU** uses the chosen
device/backend and exposes **Use CPU if the selected GPU is unavailable**.
Turning fallback off makes GPU failures stop for user action; the conversation
offers **Use CPU once** without changing saved preferences. HIP is deferred.

Device selection matches backend, description and capacity, never a saved device
ordinal. Identical ambiguous devices are rejected. Current upstream enumeration
does not provide a portable physical UUID, so this is a conservative descriptive
identity, not proof of the physical card across replacement. Discovery and
available-memory checks run again on load. Shared or unknown memory is treated
conservatively as potentially using system RAM.

Advanced controls allow automatic or bounded manual layer counts and a GPU
memory target. Pearl reserves the greater of 512 MiB or 20% of device capacity,
includes working/cache allowance, preserves context size and selects one device.
Targets are estimates, not hard VRAM caps. **Compare models on CPU and GPU**
opens the same model-comparison workflow described below. It uses repeated local
fixtures and reports model loading separately from warm answer timing.

The chat's compute button reports verified offload, CPU fallback or Model
unloaded. Its popover shows the executable, reported build, device/profile and
memory policy. If GPU inference fails, one allowed CPU retry resumes at the last
completed tool boundary. Completed identical tool calls are reused, search
requests are not replayed, and the incomplete draft is replaced. If both attempts
fail after retrieval, the conversation retains the search results. Stop cancels
retries. Applying assistant settings during an answer offers Stop & apply or
Keep editing; an idle runtime unloads before changed settings are used.

The server binds authenticated loopback only, uses no built-in network tools,
and receives fixed arguments and a minimal environment. It uses the selected
CPU thread count and two HTTP workers. Pearl imposes no resident-memory,
virtual-address or cgroup memory cap and does not terminate inference at a
fixed host-memory threshold. Operating-system and enclosing service limits still
apply. GPU selection continues to estimate available device memory. The UI and
controller add their own overhead. Closing/stopping,
locking, disabling or losing the shell connection cancels work. The runtime
unloads after idle time. There are no inference children after the owning
process exits.

## Compare models on your computer

Open **Settings → Assistant → Models → Compare suggested models**. Opening the
panel reads hardware and saved results; it does not load or download models.
Choose any of the three suggested Q4_K_M models, or the optional 350M baselines.
Each entry shows installation status, download size, license and a rough RAM
planning estimate. Estimates are advisory and do not impose a memory ceiling.

Use **Download selected missing models** explicitly, or **Compare installed
selections** to skip downloads. Choose **CPU**, **Current configuration**, or
**Compare CPU and GPU**. Quick CPU comparisons use runtime-automatic threads and
each model's profile. Current configuration preserves entered thread and token
settings. Detailed mode adds allowed CPU topology-derived thread counts, your
entered count, compatible 4K/8K contexts and your entered context. GPU comparisons
test discovered compatible devices and retain explicit offload/memory choices.
Detailed mode rotates candidate order and can take considerably longer.

Each configuration loads in isolation, verifies its model and runtime, then runs
one warm-up and three measured repetitions of two local question/follow-up pairs.
The fixtures cover memory/storage explanations and a fictional timetable with
known numeric answers. They use the same controller, tools, fallback and citation
repair as chat, with local evidence replacing network providers and page fetches.
No live searches, credentials or personal conversations are used. The runtime's
exclusive lock prevents concurrent inference. An active answer is left running
unless you choose **Stop answer and benchmark**.

Progress identifies the model, configuration, sample and phase. **Cancel** stops
the comparison and preserves completed results. **Skip current configuration**
continues with the next candidate; an in-progress file verification completes
before the skip takes effect. Closing Settings cancels, reaps inference and saves
the final checkpoint before exiting. Locking or losing the Settings connection
also cancels work.

Results sort by completion time, memory or model name. They show median first
visible answer latency, median complete-answer time and range, peak sampled
process-tree RSS, fixture pass counts and actual CPU/GPU execution. Hidden
reasoning, tool handling and citation correction count toward answer latency.
Checksum verification and load/compatibility time are separate. Token throughput
comes from runtime-reported counts/timing when available; hidden reasoning is
never counted as visible output. OS high-water sums and sampled RSS can miss brief
child-process peaks. GPU memory and separate reasoning throughput remain marked
unavailable when they cannot be measured. Disk caches are not cleared.

**Fastest successful**, **Lowest memory** and **Balanced** compare only successful
results in the same context workload. Balanced picks lower memory within 20% of
the fastest median, or its observed range if larger. Failed, truncated, incomplete,
stale, and GPU-fallback results are excluded. Fallback samples retain their actual
CPU label; they are not ranked as GPU successes. These small fixture checks do not
establish general answer quality. **Show samples** exposes the answers and errors
so you can judge the tradeoff yourself.

**Use this configuration** changes only the Settings draft, including the exact
tested model, runtime, compute, thread, context and generation choices. It preserves
your enable/disable choice and search providers. **Apply** saves it; **Discard**
restores the prior configuration. Result files and downloads are independent of
Apply/Discard.

History is stored atomically under
`$XDG_STATE_HOME/pearl/assistant/benchmarks/` (normally `~/.local/state/pearl/assistant/benchmarks/`).
Interrupted runs remain identifiable. **Export selected comparison** saves JSON;
**Delete selected comparison** removes only that history file. Changes to model
files/revisions, runtime executable, fixture version, CPU/affinity, OS, observable
GPU/driver identity or power profile mark results stale on refresh and prevent
adoption. Runtime capability/device checks still run again before inference;
fingerprints are not a substitute for those checks.

## Floating window integration

The chat is a separate GTK toplevel; it does not share the launcher's popup
lifetime. A private inherited socket ties its lifetime and authorization to the
verified shell session, and the launcher waits for handoff acknowledgment.
This replaces the plan's public per-session activation socket with a smaller
parent-owned connection; prompts never appear in argv or status logs.

Automatic first-map floating placement requires the narrow
[`aqueous-floating.patch`](../packaging/assistant/aqueous-floating.patch) against
Aqueous revision `88587243059d58d72dd0fe2146d0ebdb64f26474`, or an upstream version
with equivalent support. The patch uses the exact release and Git app IDs,
centers a 440 × 560 window on its admission output, and preserves explicit user
rules. It does not edit user configuration. Without it, the compositor's
ordinary placement policy applies. Pearl cannot force floating from GTK alone.

History keeps up to five conversations in session memory. The History button
cycles them; New creates a conversation. Enter sends, Shift+Enter inserts a
line, Escape stops work or hides the idle window. Close cancels/hides; Resume
conversation reopens it. Follow-up drafts survive a running answer. Source URLs
come from the provider records, never from generated text.

Responses stream into a visibly marked draft; source IDs are checked before
the completed answer replaces it. The controller allows six tool calls, two
search rounds and three result-page reads per turn. Turn deadlines are three
times the model profile's per-inference deadline (60–300 seconds).
It preserves the submitted question when fitting history into the context.

`pearlctl assistant status` reports enabled/running/locked/handoff state, selected
runtime/mode and current compute activity without prompt bodies. `show` resumes
the window, `clear` erases session conversations, and `stop` terminates the
assistant and runtime, clearing session history. `cancel` stops the current
answer while retaining the conversation; `release` unloads only an idle runtime
and refuses a busy answer.
These controls use Pearl's existing authenticated session control channel.

## Validation and remaining qualification

Run policy/native tests with `zig build test-agent`. This includes offline HTTP/SSE
fixtures for direct chat, optional search, provider failure, chat-only capability
gating, citation correction, whole-turn context pruning, streaming, truncation,
and cancellation; these need Python but no real model or web access. Build the instrumented
frontend with `zig build build-agent-test`. Real-model and private-desktop tests
are in `tests/integration/test_agent_model.py`, `test_agent_ui.py` and
`test_agent_launcher.py`; none downloads models or uses live search credentials.
`test_agent_runtime.py` uses an executable protocol fixture to simulate GPU
enumeration, verified/unverified offload, device failure, version changes and
missing authentication. Its passing results do not establish real GPU support
on a particular driver. Use `test_agent_ui.py --runtime /absolute/mistralrs`
to exercise a custom installation with the real local model.

`zig build test-agent-model-settings` checks the model selector, draft isolation,
and saving larger thread/context/generation values through native controls without
loading or downloading a model. To check all three new models with local search
fixtures, supply their existing GGUF files and a compatible runtime:

```sh
zig build build-agent-test
python3 tests/integration/test_agent_models.py --models-dir /path/to/models \
    --runtime /absolute/mistralrs --output /tmp/pearl-model-check
```

This is a compatibility smoke test. The implemented comparative benchmark has
separate integration checks:

```sh
zig build test-agent-benchmark test-agent-benchmark-settings -- \
    --model /path/to/LFM3-1.7B-Q4_K_M.gguf
zig build build-benchmark-check
```

The test driver `zig-out/test/pearl-benchmark-check INPUT.json` accepts an object
with `config` (assistant preferences) and `options` (`selected`: five catalog-order
booleans, `mode`: `cpu`, `current` or `cpu_gpu`, and `detailed`: boolean). It uses
the caller's XDG directories, prints the run as JSON and saves the same history as
Settings. It never downloads. Use isolated XDG directories for automated tests.
The fixture suite verifies fallback, citation correction, truncation, GPU failure,
cancellation, skipping, checksum/missing-runtime errors and persistence. The native
suite verifies draft adoption, Apply/Discard, stale results and shutdown cleanup.

The three suggested models completed 48 fixture answers/follow-ups (36 measured,
12 warm-up) on a Ryzen 9 9950X3D CPU. This is one-machine validation with background
activity, not a general model ranking or physical GPU qualification. Recorded
configuration and samples are in
[`cpu-fixture-report.json`](../artifacts/assistant/model-benchmarks/cpu-fixture-report.json).

After staging the runtime and supplying an existing model, run the real
launcher/settings test with:

```sh
zig build test-agent-launcher -- --model /path/to/LFM3-1.7B-Q4_K_M.gguf \
    --aqueous /path/to/patched/aqueous
```

The compositor patch was built and exercised in a separate test checkout.
No running desktop or system package was changed. Native screenshots and
acceptance reports are under [`artifacts/assistant`](../artifacts/assistant/).

The 350M model can request a search and summarize returned evidence, but it can
omit citations, answer before searching, or produce misleading follow-ups.
Pearl bounds tool calls and requests one correction if the model skips searching.
If it still skips searching, Pearl searches for the submitted question and feeds
the evidence back into the model to finish the answer. This counts toward the
search budget. Answers still receive one citation correction attempt; Pearl
rejects unknown citations and shows ordinary results when the model cannot
produce a valid cited answer.
Citation-ID validation does **not** prove that the answer is supported by the
source. The plan's 100-question human-reviewed evaluation and low-end 6 GB
hardware qualification remain required before describing this as reliable on
all supported CPUs.

Implementation status and measured test results are recorded with the private
test artifacts; source availability, unit-test success and a single real-model
round trip are not a model-quality certification. AArch64 and older non-AVX2
hardware require separate builds and measurements.

Physical Vulkan/CUDA, AMD/Intel shared-memory behavior, host memory pressure
and independently packaged upstream versions still need qualification. The
current environment has no GPU device nodes. Reported CPU measurements and
simulated GPU recovery tests must not be presented as GPU performance evidence.

The initial implementation uses native GTK controls with English assistant
copy, a History button that cycles session conversations, and a private
parent-child activation channel. Broader translation/accessibility/scaling
qualification, the 100-question supported-answer evaluation, live paid-provider
checks and Q8_0/AArch64/older-CPU qualification remain release work. The Q4
fixture tests establish the tool and UI flow, not broad answer reliability.
