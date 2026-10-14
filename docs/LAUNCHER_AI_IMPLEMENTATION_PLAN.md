# Launcher AI implementation plan

Status: experimental implementation added, October 14, 2026. See
[Assistant implementation and setup](ASSISTANT.md) for the implemented behavior,
build instructions and remaining qualification gates. The model-quality and
hardware targets below remain release gates, not completed measurements.

Add an optional local assistant to Super+Space. A user types a question, presses
Enter on **Ask Pearl**, and a small floating conversation window opens. Pearl
queries the user's configured search providers, reads selected results and uses
the selected local model to produce a brief answer with sources. Follow-up
questions stay in that window. Application launching, window switching and the
calculator remain available without AI.

The initial model is **LiquidAI/LFM2.5-350M, Q4_K_M**. Model selection is a real
setting: ship tested profiles for its Q4_K_M and Q8_0 variants and allow local
GGUF imports that pass a tool-use compatibility check. A successful GGUF load
alone does not establish assistant compatibility.

## Visual reference

- [Mockup guide](mockups/launcher-ai/README.md)
- [Interaction flow](mockups/launcher-ai/flow.png)
- [Opt-in and model settings](mockups/launcher-ai/settings.png)
- [Search provider settings](mockups/launcher-ai/providers.png)
- [Launcher handoff and floating conversation](mockups/launcher-ai/conversation.png)
- [Narrow window and recovery states](mockups/launcher-ai/recovery.png)

The SVG sources are editable design assets, not application code. Mockup frames,
step numbers and explanatory captions are presentation material. Production UI
is native GTK4 in Zig and follows Pearl's active theme. Example answers and
provider statuses are illustrative, not live search results.

## Scope and defaults

| Decision | Initial behavior |
| --- | --- |
| Opt-in | Disabled on fresh installs and when older preferences omit the field. |
| Disabled footprint | No agent process, model load, model download, classification inference or search request. |
| Initial model | LFM2.5-350M Q4_K_M; approximately 229 MB of weights. Q8_0 is approximately 379 MB. |
| Providers | Google is selected by default through a user-configured SearXNG instance. Also support general SearXNG, Brave Search API and existing-account Google JSON API connections. No endpoint is configured or contacted automatically. |
| Network trigger | Enter or a deliberate Ask/Send activation; typing never sends text to a provider. |
| Conversation | One floating window per verified Pearl session; in-memory conversations by default. |
| Scope of tools | Web search and reading search results. No shell, desktop actions, file writes or arbitrary MCP servers. |
| Local files | Semantic file indexing remains a separate feature; no embedding model is needed for this release. |
| Hardware | Preserve the 4 GB non-AI baseline; target 6 GB total RAM with AI and CPU-only inference. |

Liquid documents tool use and CPU-oriented GGUF deployment for this model.
The weight sizes are download sizes, not total resident memory. Complex
multi-source synthesis and reliable citations require evaluation on Pearl's
actual workflow. [Model card][model] · [Model files][weights]

## User interaction

### Enable and prepare

Add **Assistant** under Desktop in Pearl Settings, with General, Models and
Search engines sections. The master switch participates in the normal draft,
Apply and Discard workflow. Explain next to it: “Answers are generated on this
device. Web questions are sent to your selected search engines.”

Enabling saves the preference but does not start a model download. Readiness
requires both a verified model and at least one tested, enabled provider. Show
separate readiness rows and clear actions: Download model, Add search engine,
Test connection. The Download button names the model, size and publisher and
links its license. Importing an existing local GGUF works without a download.

Model installation and explicit connection tests are immediate operations with
their own progress, cancellation and error state. They do not silently Apply
unrelated preference edits. Download completion never changes the selected
model without a saved selection. Discard does not pretend to undo an already
completed download; Remove download is a separate action.

### Ask from the launcher

Keep the existing search field. When enabled, its placeholder becomes “Search
apps, calculate, or ask a question”. Add a typed Ask result with a speech-bubble
icon, the submitted text and “Web answer · <default provider> · Enter to ask”.

Implement a cheap, pure Zig intent policy, with no model running on keystrokes:

1. Explicit calculator mode and valid calculation results keep their current
   behavior. Exact application/window matches remain selected ahead of an
   implicit question result.
2. A leading `?` explicitly selects Ask for any nonempty text.
3. Natural question forms, including “how”, “why”, “what”, “can”, “is” and their
   supported localized equivalents, or a trailing question mark, promote Ask
   when there is no stronger exact result. A question mark is not required.
4. Other nonempty text always offers Ask below normal results while enabled.
   Do not turn every unsuccessful app search into an automatic web request.
5. Arrow keys choose the action; Enter activates only the selected fresh row.
   Preserve IME composition, edit revisions, session IDs and stale Enter checks.

Allow up to 2,048 UTF-8 bytes for an Ask query; cap provider-specific query
length separately. Revisit the existing launcher's 512-byte cap deliberately.
Never silently truncate the original question. A model-generated search query
can be shorter than that question.

On Ask activation, immediately create/present the chat with the submitted
question and a cancellable Preparing state. Close the launcher only after
handoff acknowledgment. Failure to launch leaves the query and an actionable
error in the launcher. Use an idempotent request ID so retries cannot send the
same question twice. If enabled but unconfigured, open a setup state in the
chat with a Settings action and preserve the question for explicit Retry.

### Continue in a floating window

Use a separate GTK application, proposed executable `pearl-agent`, modeled on
Pearl Settings' verified session connection and singleton activation. Give it
app ID `org.aqueous.Pearl.Agent` and a distinct `-git` package identity. Initial
size is 440 × 560 logical pixels, minimum 320 × 400, clamped to the work area.

It is a regular resizable, movable toplevel with an Aqueous floating policy,
not the launcher's dismiss-on-outside-click layer surface. The session manager
must arrange float placement before first visible placement where possible.
Use an existing supported compositor rule/API if available; otherwise add a
narrow app-ID placement contract in Aqueous. This is an explicit dependency in
the first milestone: GTK default size does not guarantee floating on a tiler.
Do not silently edit the user's window-rule file or claim an xdg-toplevel can
position itself. Center on the invoking output initially; retain user moves
while open. Output removal clamps/moves it to a surviving work area.

Header: Pearl Assistant, selected model, provider menu, New chat, minimize and
close. Body: user turns, concise activity labels, assistant answers, expandable
Sources. Footer: multiline composer, Send/Stop, and “Answers on device · Web
search online”. Enter sends; Shift+Enter inserts a newline; IME Enter commits
composition first. Retain an unsent follow-up while a response is running;
never queue an invisible second request. Stop retains partial text labeled
“Stopped”. Auto-scroll only while the reader is already at the bottom.

Clicking outside does not dismiss the window. Escape stops active work first;
when idle it hides the window. Close also cancels active work and hides it.
Keep up to five conversations in session memory, accessible from the header
menu and a **Resume conversation** launcher row; New chat or a fresh launcher
question creates a new conversation. Bound history to 20 user turns and 128 KiB
per conversation, visibly dropping the oldest turns when necessary. Do not
reopen or refocus the window because an answer finishes.

No conversation persistence in v1: closing the Pearl session or turning the
feature off clears chat memory. Hide and cancel on lock/inactive session;
require explicit Resume after unlock, never resume web work automatically.
Loss of the verified shell connection cancels work and releases the model.

## Settings and model selection

| Setting | Default and behavior |
| --- | --- |
| Enable assistant | False; live Apply disabling cancels all work, closes chat, unloads runtime and clears conversations. |
| Selected model | Stable registry ID for LFM2.5-350M Q4_K_M, initially not installed. |
| Model management | Download, cancel, retry, verify, remove, import local GGUF; show progress and disk use. |
| Search engines | Editable ordered list; explicit enabled/default choices, endpoint, provider options and credential reference. |
| Search mode | Default engine only; optional “All enabled engines”, capped at three. No silent fallback to an unselected engine. |
| Read result pages | Enabled with opt-in; explain that selected websites receive page requests. |
| Search locale / safe search | System language; provider-supported safe-search level, clearly showing unsupported options. |
| Resource preset | Balanced: 4,096-token context, short answers, at most two CPU threads, 60-second idle unload. |
| Advanced limits | CPU thread cap, context 2,048/4,096, answer length up to 512 tokens, idle timeout. Bounds remain enforced. |
| Conversation storage | “This session only”; Clear conversations action. |

Selection is separate from installation. Display installed model profiles with
name, quantization, download size and readiness. Q4_K_M is the recommended
profile; Q8_0 is an alternate precision profile of the same model. Import gives
a custom model a stable ID and records architecture, tokenizer, context limit,
chat-template digest and tool adapter. Reject malformed/oversized metadata.

Custom models must pass load, tool-call generation, tool-result consumption and
plain-answer smoke checks before they can be selected for the assistant. Show
“Not compatible with assistant tools” with a reason on failure. Only profiles
within the active resource allowance are eligible. The registry can later ship
other tested models without changing providers or launcher code.

Switching a model during a response applies to the next turn; do not change the
running turn's model midstream. Show a pending-change badge. Keep only one model
resident: unload the old runtime before loading the new one. Replay bounded
role/source history using the new profile, never reuse incompatible KV state.
Removing a model in use requires stopping that work and selecting another;
the UI provides this concrete action rather than deleting an open file blindly.

Proposed preference shape (illustrative, not an implemented schema):

```json
{
  "assistant": {
    "enabled": false,
    "model_id": "liquid-lfm25-350m-q4km",
    "search_mode": "default",
    "default_provider_id": "google",
    "providers": [{"id":"google","name":"Google","kind":"google","enabled":true,"endpoint":""}],
    "read_pages": true,
    "context_tokens": 4096,
    "answer_tokens": 384,
    "cpu_threads": 2,
    "idle_unload_seconds": 60
  }
}
```

Provider entries include stable ID, kind, enabled, display name, endpoint,
credential reference, language, safe search and SearXNG engine allowlist.
Validate IDs, endpoint schemes, counts, string sizes and referential integrity.
An empty provider list is a valid unconfigured state. A removed default must be
explicitly replaced or cleared. Add migrations/default tests and conflict-aware
draft merging. Keep credentials and installed-model state out of preference
exports, raw JSON editors, reports and configuration backups.

Use the Secret Service API through a Zig D-Bus client for stored provider keys.
If no secret service is available/unlocked, offer a session-only key; do not
silently persist plaintext. Settings masks keys and supports replace/remove.
The agent receives only credentials for the selected provider, never includes
them in prompts, and strips them from logs and errors.

## llama.cpp pin and build

**Build llama.cpp v0.6.0, commit
`d81235049384534c167caea52b85a694f6103d14`.** This is the inspected October 5,
2026 release. Pin the full commit and source archive checksum in packaging;
never follow `master`, `latest` or an unverified system executable at runtime.
Record this pin in the build report. [Release][llama-release] · [Commit][llama-commit]

Use a managed **llama-server subprocess** for the initial implementation. It
already provides tokenization, chat templates, streamed completions and tool
transport. This avoids introducing Pearl-owned C++ chat-template bindings.
All Pearl orchestration, settings, networking, extraction and UI remain Zig;
upstream C/C++ inference and its CMake build are the necessary dependency
boundary. Drive packaging from Zig build steps using fixed argv.

Proposed Linux CPU build recipe, run against the pinned checkout:

```sh
cmake -S third_party/llama.cpp -B build/llama-cpu \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=ON \
  -DGGML_CPU_ALL_VARIANTS=ON \
  -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF \
  -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build build/llama-cpu --target llama-server --parallel 2
```

Package the executable and its exact shared libraries/CPU backends in a private
Pearl libexec directory with controlled runtime library lookup. No compilation
or source fetching on end-user machines. Keep the optional runtime package
separate from non-AI Pearl. Disable upstream UI downloads and package only the
server assets needed. Verify configuration produces no unused-option warnings.
CPU variants require dynamic backends; the base executable and generic backend
must not acquire host-specific instruction flags. Test the baseline on x86-64
without AVX2 and produce a separate AArch64 build. “Any CPU” means supported
architectures with a working fallback, not a latency guarantee. [Build options][build-options]

Launch one server with a verified local model path, `--jinja`,
`--host 127.0.0.1`, a dynamically chosen port, `--api-key-file` pointing to a
0600 per-session file, `--no-webui`, `--no-agent`, `--ctx-size 4096`,
`--parallel 1`, `--threads 2`, `--threads-batch 2`, `--batch-size 128`,
`--ubatch-size 64`, `--gpu-layers 0` and `--poll 0`. Reduce thread counts on
single-core hosts. Pass no `-hf` download argument. Override inherited server
configuration/environment with an allowlist. Do not enable built-in network
tools, MCP, remote backends or external model URLs. [Server options][server]

The Zig controller allocates a candidate port, starts the child, retries a
bounded number of bind collisions and verifies both process liveness and an
authenticated model response before use. A public health endpoint alone does
not identify the expected child. Use fixed argv, private files, process-group
cleanup and an exit watch. Close/cancel the streaming request on Stop; verify
inference actually stops, killing/restarting the owned child after a short
grace interval if necessary. No orphan server after logout or a UI crash.

### Mandatory compatibility gate

Do not infer full LFM support from GGUF loading. Before UI implementation,
build the exact pin and selected weights and demonstrate:

1. Plain streamed text with the embedded chat template.
2. Correct `search_web` name and arguments from the actual tools schema.
3. Tool result insertion followed by a grounded answer and source IDs.
4. A second `read_page` call, follow-up question, malformed-call rejection and
   cancellation during both prefill and decoding.
5. Correct behavior after unload, process restart and model switching.

LFM documents a Python-like tool-call format and an optional JSON format;
llama.cpp's tool support depends on template/parser compatibility. Prefer
structured `tool_calls` from the server. If this profile returns tagged text,
use a bounded Zig parser for its documented call grammar or a validated JSON
adapter; never evaluate model output as Python or shell. Hide incomplete tool
syntax from streamed prose. Any template override is pinned and tested per
model. If the release fails these tests, isolate the issue and deliberately
revise the pin or adapter; do not silently track nightly builds. [LFM tools][tools]

The model manifest must record the immutable Hugging Face revision, file SHA256,
expected byte count, license and template/profile digest before downloads ship.
This plan identifies the model filenames but does not invent an unverified
weight checksum. Fetch to a partial file, check available disk, support
cancellation/resume with entity validation, hash before atomic rename and
retain a known-good installed model on failure. Treat imported GGUFs as data
and inspect them in the isolated runtime, without executing remote code.

## Agent loop and source handling

`pearl-agent` owns the GTK chat and a Zig controller; HTTP, extraction and
inference transport run off its GTK thread. Shell IPC provides committed
configuration, lock/session state and revocation. Use a bounded, versioned,
same-user Unix socket protocol with session identity, conversation ID, turn ID
and generation on every event. Settings subscribes to model/download/test
status without starting inference. Share service contracts, not GTK widgets.

State machine:

```text
submitted → preparing → deciding → searching → reading → answering → idle
                ↘ setup needed           ↘ partial results
any active state → stopping → stopped
any active state → failed → explicit retry
lock / disable / session loss → cancel and release runtime
```

The model may request `search_web(query, provider_id?)` and
`read_page(result_id)`. Optional provider IDs must belong to the saved enabled
selection; otherwise reject the call. Search mode determines the authorized
provider set. Every launcher-originated question performs at least one search
attempt before being presented as a web answer. If the model tries to answer
without searching, make one corrective tool request; if it still fails, show
ordinary search results using the submitted query and mark the summary
unavailable. Do not disguise a scripted fallback as a successful model call.
Follow-ups can reuse current evidence or search again; a Refresh sources action
forces a fresh request.

Allow at most two search rounds, three result-page reads and six total tool
invocations per user turn. Deduplicate identical calls, canonicalize safe URLs
for display, retain provider attribution and do not merge unrelated pages by
title. Limit results to five per provider and select evidence within a token
budget. Buffer tool arguments until a complete call validates. A single
repair attempt is allowed; never run partial JSON or fabricated tools.

The host, not the model, owns source IDs, URLs, titles and retrieval timestamps.
Pass source text as untrusted evidence, separate from tools and instructions.
Do not give this release any tool capable of shell execution or changing
settings. Render escaped text and a small Markdown subset without raw HTML,
remote images or executable links. Only resolve citations to known source IDs;
unknown IDs are visibly unverified and never become invented links. Validate
literal quotations where present. Valid source IDs do not prove that a claim
is supported; evaluate that separately and allow “Not enough evidence”.

Use a fixed 4,096-token total budget initially: reserve approximately 512 for
instructions/tool schemas, 1,024 for recent conversation, 1,800 for evidence,
512 for completion and the remaining margin for formatting. Measure using the
selected model's tokenizer, including tool-call/result messages. Trim old
evidence/history before admitting a request. Never let the server silently
discard the policy or newest question. Show “Earlier messages are no longer
in context” when trimming changes the conversation context. Long sources are
reduced to query-relevant passages in Zig, not repeatedly summarized by another
model. Recalculate all allowances when a custom model has a smaller context.

## Search engines and page extraction

Google is the initial provider selection. Its supported default connection is
the Google engine on a SearXNG instance chosen by the user (`engines=google`).
Do not silently select a public SearXNG instance. The instance must enable
Google and permit JSON responses. No request is sent until an explicit Ask or
connection test. This is Google through SearXNG, not a direct Google API.

Keep a distinct legacy Google API adapter for existing credentials (`key` and
`cx`), with secrets in Secret Service. Google's Custom Search JSON API is
closed to new customers and scheduled to end January 1, 2027; it cannot be the
general onboarding path. Display that restriction beside this connection type.
[Google API lifecycle](https://developers.google.com/custom-search/v1/overview).

Implement a provider interface returning normalized result ID, provider, title,
URL, snippet and optional publication date. Retrieval time is not publication
time. Initial adapters:

- **Brave Search API:** HTTPS request with its subscription header; key required.
  Use web results, not a paid remote answer-generation service. Handle invalid
  credentials, quota/rate limits, timeouts and Retry-After. [Brave API][brave]
- **SearXNG:** configured instance URL, JSON search endpoint and optional engine
  allowlist. Test JSON availability; instances can disable this format. Do not
  silently choose a public instance. [SearXNG API][searx]

Expose Add, Edit, Test, enable/disable, Make default and Remove. Tests send a
visible fixed sample query only after the user presses Test. In all-engines
mode show successful and failed providers separately and summarize usable
results without claiming complete coverage. No automatic provider change
after credentials or quota failure. Adding other commercial engines requires
an actual API adapter; a browser search URL is not a machine-readable API.

Use Pearl's existing libcurl dependency via Zig for HTTPS and cancellation.
For readable HTML extraction, add libxml2 through its C API with external
entities/network loading disabled; parsing real HTML is the documented reason
for this native dependency. Strip scripts, navigation, forms and boilerplate;
prefer article/main content and meaningful headings. Plain text is supported.
No JavaScript browser, login cookies, PDF/OCR or paywall bypass in v1. Mark
snippet-only evidence explicitly when page extraction is unavailable.

Bound each response by compressed and decompressed size (2 MiB page body,
256 KiB extracted text before passage selection), redirects (three), connection
timeout (five seconds), request timeout (15 seconds) and concurrent fetches
(two). TLS verification stays enabled. Search-result reads accept only HTTP(S)
URLs from that turn's registry, with DNS/IP checks on every redirect and pinned
connections preventing rebinding. Block loopback, private, link-local and
metadata endpoints for result-page reads. A user-configured private SearXNG
endpoint is a separate, explicit exact-origin exception, not permission to
fetch private URLs returned in results. Never forward provider credentials to
result pages or across redirects. Do not inherit browser cookies or proxy
credentials. Label provider snippets and fetched pages distinctly in Sources.

## Resource and privacy contract

- Target additional peak memory below **1.5 GiB** across the chat/controller,
  runtime, token buffers and fetch workers; leave headroom within the user's
  approximate 2 GB allowance. Measure the process tree/cgroup, not just weights.
- One resident model and one active turn; unload after 60 idle seconds by default.
  Bound transcript, result cache and download buffers. Model mappings remain
  reclaimable; do not lock weights into RAM. Check available memory before load.
- Cap CPU work at two threads and lower scheduling priority. Leave a core free
  where possible. No inference on typing and no startup model warming by default.
- Use a bounded turn deadline (90 seconds initially), visible elapsed activity,
  Stop, and ordinary result links if generation is too slow. Deadline failure
  must not discard already received results.
- Sample memory pressure; cancel before destabilizing the desktop. Where user
  cgroup delegation exists, constrain the agent process group and record
  memory.current/peak. Otherwise use process-tree monitoring; an allocation
  limit alone is not a reliable resident-memory guarantee.
- Default private data stays in session memory, with no query/body logging.
  Diagnostics contain stages, timings, counts and redacted errors only. Source
  fetching still communicates with external sites; local inference is not an
  offline-search claim.
- Turning off the saved preference revokes outstanding work immediately. Model
  files can stay on disk for re-enabling; provide explicit Remove downloads.
  An unconfigured/disabled assistant never sends opportunistic telemetry.

## Repository integration

| Existing area | Proposed change |
| --- | --- |
| `src/desktop/launcher.zig` | Add typed Ask and Resume rows, intent policy, fresh activation and acknowledged handoff. |
| `src/desktop/policy.zig` | Preserve ranking; put new pure question policy in `src/agent/intent.zig`. |
| `src/ui/surfaces/manager.zig` | Launcher-to-agent activation, output context and session revocation; no chat lifetime in popup state. |
| `src/desktop/settings_navigation.zig` | Add noncompact `assistant` route and translations. |
| `src/settings/window.zig` and editor protocols | Add dedicated `assistant_view.zig`, model/provider forms and draft integration. |
| `src/config/preferences.zig`, `service.zig`, `draft.zig`, `merge.zig` | Strict defaults, validation, atomic apply, conflicts and live revocation. |
| `src/settings/launch.zig`, `instance.zig`, `distribution.zig` | Reuse the patterns for fixed argv, activation, package identity and session-scoped singleton; do not couple settings and agent instances. |
| `src/config/helper_process.zig` | Reuse bounded process cleanup principles; implement a dedicated persistent supervisor rather than buffering a long-running server as a one-shot helper. |
| `src/cli/options.zig`, `protocol.zig`, `server.zig` | Add bounded agent status/show/stop and settings route support; do not expose prompt bodies in status. |
| `build.zig`, packaging | Optional agent/runtime targets, pinned upstream build, desktop entry, CPU backends and license notices. |
| Aqueous placement | Confirm/add floating placement for the exact agent app ID, before first map. |

Proposed new Zig modules under `src/agent/`: `intent`, `config`, `model_registry`,
`downloads`, `credentials`, `protocol`, `client`, `instance`, `runtime`, `llama`,
`tool_codec`, `controller`, `conversation`, `sources`, `providers`, `fetch`,
`extract`, `budget`, `application`, `window` and `view`. Provider adapters can
live under `providers/`. Add `src/agent_main.zig`. Split modules as their actual
ownership warrants; avoid a general plugin framework for two search tools.

## Delivery sequence and acceptance

| Phase | Work | Exit evidence |
| --- | --- | --- |
| 1. Runtime and surface spike | Build pinned llama.cpp; validate model/template/tools; create floating native chat on the invoking output. | Real search-tool round trip with a local fixture, correct follow-up, cold/warm memory and timing, float/focus proof. |
| 2. Configuration and model lifecycle | Off-by-default schema, draft settings, registry, downloads/imports, credentials, readiness and revocation. | Old-config migration, interrupted download, wrong hash, missing runtime, model switch, disable during work. |
| 3. Search and bounded agent loop | Provider adapters, page extraction, tool parsing, citations, budgets and cancellation. | Deterministic provider fixtures plus explicit live smoke tests; partial failures and unsupported evidence states. |
| 4. Launcher and chat | Ask ranking, handoff, streaming, sources, follow-ups, session history and accessible keyboard flow. | Existing launcher/calculator regressions, no network on typing, no duplicate turns, close/lock/output recovery. |
| 5. Packaging and qualification | CPU builds, optional install, translations, resource tests and answer-quality evaluation. | Measured 6 GB system behavior, quality scorecard and documented CPU support envelope. |

Phase 1 is the go/no-go point for the model. Keep the requested LFM default
provisional until it can search, consume tool results and summarize accurately.
If quality fails, report that outcome and evaluate another selectable profile;
do not silently change the shipped default or claim a benchmark win.

## Validation plan

Use Zig unit tests for intent/precedence, config validation and migration,
model capability selection, parser fuzz cases, budgets, source-ID resolution,
history pruning, URL policy and state-machine cancellation. Use deterministic
fake runtime/provider servers for protocol and UI integration; Python is
permitted only for tests under the repository policy. Reuse private HOME/XDG,
D-Bus and Aqueous harnesses, never user credentials or the live desktop.

Required behavior checks:

- Disabled and fresh-install paths perform zero AI downloads, process starts or
  search requests. Enable without readiness shows setup, not an invented answer.
- Enter activation uses current text even during ranking, IME composition and
  rapid editing. Calculator/app/window behavior and normal search latency hold.
- Split SSE frames, partial UTF-8, malformed calls, repeated calls, quota errors,
  oversized/decompression-bomb bodies, redirects, DNS rebinding and hostile
  page instructions cannot escape the authorized tools or budgets.
- Both provider types, all-engines partial failure, model/template switching,
  missing/deleted model, hash failure and secret-service lock/unavailability.
- Stop/close/disable/lock/logout kill work, suppress late responses and release
  processes. Reopening restores session text without silently resubmitting it.
- Keyboard-only navigation, screen-reader labels, reduced motion, selection
  preservation, source links, long answers, narrow 320-pixel width, light/dark
  themes, 1×/1.25×/2× scaling and translated labels.

Maintain a versioned evaluation set of at least 100 representative questions,
including follow-ups, ambiguous wording, conflicting sources, unanswerable
questions and page prompt injection. Judge source support and summary quality
independently of citation syntax. Proposed release thresholds: at least 95%
valid authorized tool calls, 90% successful tool-result continuation and 90%
human-reviewed supported summaries on answerable cases; 100% citation IDs
resolved by the host and zero unauthorized execution/network destinations.
Track abstention and unsupported-claim rates separately. Thresholds are release
criteria, not assertions about this 350M model.

Measure cold load, time to first useful result, prefill/decode speed, full-answer
latency, CPU use, energy where available and process-tree peak memory. Test
4 GB with AI disabled and 6 GB with normal desktop applications plus AI, as
well as low-memory injection and a single-core/older x86-64 CPU. Do not use an
arbitrary fast workstation to certify “any CPU”. Require responsive launcher
input and no desktop OOM; publish measured summary latencies per test CPU.

## Qualification gates after implementation

1. The Q4 native tool-call loop and immutable model hashes are implemented and
   exercised with a local search fixture on the exact runtime pin. Expand this
   to the versioned 100-question, human-reviewed quality evaluation above.
2. A narrow Aqueous patch implements first-map floating placement and was built
   and tested in a private checkout. Distributions must apply that patch or use
   an upstream version with equivalent behavior; it is not installed on the
   running desktop by this implementation.
3. Establish whether Q4_K_M meets summary/citation accuracy. Compare Q8_0 within
   the same resource envelope before considering a larger model.
4. Verify the runtime packaging recipe on both supported CPU architectures,
   including the generic CPU fallback and all private shared libraries.

[model]: https://huggingface.co/LiquidAI/LFM2.5-350M
[weights]: https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/tree/main
[tools]: https://docs.liquid.ai/lfm/key-concepts/tool-use
[llama-release]: https://github.com/ggml-org/llama.cpp/releases/tag/v0.6.0
[llama-commit]: https://github.com/ggml-org/llama.cpp/commit/d81235049384534c167caea52b85a694f6103d14
[build-options]: https://github.com/ggml-org/llama.cpp/blob/v0.6.0/ggml/CMakeLists.txt
[server]: https://github.com/ggml-org/llama.cpp/blob/v0.6.0/tools/server/README.md
[brave]: https://api-dashboard.search.brave.com/api-reference/web/search/post
[searx]: https://docs.searxng.org/dev/search_api.html
