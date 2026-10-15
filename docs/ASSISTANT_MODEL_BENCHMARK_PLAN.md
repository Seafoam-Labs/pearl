# Assistant model benchmarking and selection plan

Status: comparison workflow implemented, October 15, 2026. The design below is
implemented in [`benchmark.zig`](../src/agent/benchmark.zig),
[`telemetry.zig`](../src/agent/telemetry.zig) and the native
[`benchmark_view.zig`](../src/settings/benchmark_view.zig). See
[usage and validation](ASSISTANT.md#compare-models-on-your-computer).

The implementation includes explicit candidate downloads, CPU/current/CPU-and-GPU
modes, detailed thread/context candidates, local fixtures through the production
controller, cancellation and skipping, atomic history, export/delete, stale-result
checks, transparent suggestions, and draft-only adoption. Closing Settings waits
for cancellation and runtime cleanup. GPU failures retain their actual CPU/mixed
sample results and are excluded from successful GPU recommendations.

Qualification remains ongoing: the three suggested models passed the local CPU
fixtures on one Ryzen 9 9950X3D. Broader human-reviewed quality evaluation, older
x86/AArch64 machines, and physical discrete/shared-memory GPU testing require
additional hardware and review. Runtime GPU memory and separate visible/reasoning
throughput are reported unavailable where the runtime provides no measurement.
The original design and acceptance criteria follow.

Let users compare Pearl's suggested models on their own CPU or GPU and choose a
model and configuration based on measured response time, memory use and usable
answers. Benchmarking must use the same runtime and inference path as chat, so a
fast benchmark result corresponds to a configuration the user can actually use.
All application logic, measurements and persistence will be implemented in Zig.
Python may drive isolated integration tests.

## Starting models

The initial comparison offers the three new Q4_K_M suggestions, with the
existing 350M profiles available as optional baselines:

| Model | Download | Intended comparison |
| --- | --- | --- |
| Qwen3-4B-Instruct-2507 | 2.50 GB | General answers and tool use without a separate thinking phase |
| LFM2.5-2.6B | 1.67 GB | Tool use and answers from evidence, including reasoning time |
| LFM2.5-1.2B-Instruct | 731 MB | Lower memory use and response latency |

These roles define what to measure, not a ranking on untested hardware. The
catalog pins download revisions and checksums. Downloads remain explicit, and
file size must be shown separately from measured runtime RAM.

Model references: [Qwen model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507),
[Qwen GGUF files](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/tree/main),
[LiquidAI 2.6B model card](https://huggingface.co/LiquidAI/LFM2.5-2.6B),
[LiquidAI 2.6B GGUF files](https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/tree/main),
[LiquidAI 1.2B model card](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct),
[LiquidAI 1.2B GGUF files](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/tree/main).

## User workflow

1. Add **Compare suggested models** to Settings → Assistant → Models. Show the
   current CPU, available RAM, selected runtime, and discovered GPU configuration.
   Show each candidate's download size, installation status and license link.
2. Let the user select models and either **CPU**, **Current configuration**, or
   **Compare CPU and GPU**. Show pending download totals. Offer an explicit
   download action or compare only already installed models. Opening the page
   must not download, load a model or run a benchmark.
3. Offer a quick comparison using runtime-auto threads and a detailed comparison
   that tests additional thread counts and context sizes. Keep custom thread and
   context values available; recommended candidates are not hardware caps.
4. Run one configuration at a time. Show model, actual backend, current test,
   completed samples and a Cancel button. Offer Stop answer and benchmark if
   chat is busy; otherwise leave the current answer running. Reuse the exclusive
   runtime lock, unload between candidates, and stop/reap each owned process.
5. Present a sortable comparison table and the generated sample answers. Let
   the user choose **Use this configuration** to update the Settings draft.
   **Apply** persists it and **Discard** restores the prior configuration.
   Downloaded files and completed benchmark history remain independent of Apply.

## Measurements and fair comparisons

Use versioned local fixtures with identical questions and supplied evidence.
Do not include live search latency, API credentials or personal chat history.
Exercise tool requests, the host-search fallback, evidence-based answers,
citation correction and a follow-up question through the production controller.
Inject local search fixtures through a testable provider boundary.

Record these values for every model and configuration:

| Measurement | Meaning |
| --- | --- |
| Load and compatibility time | Time from starting a fresh runtime to readiness; report checksum verification separately |
| First visible answer latency | Time from submission to the first answer token, including any hidden reasoning and tool handling |
| Complete answer time | Time until the validated final answer is available, including correction attempts |
| Prompt and generation throughput | Runtime-reported token counts and timing, separately for input, reasoning and visible output when available |
| Peak resident RAM | Sampled process-tree RSS plus available OS high-water information; identify sampling limitations |
| GPU memory and actual offload | Device/backend, verified offloaded layers and memory measurements when available |
| Completion result | Answer, results-only fallback, timeout, cancellation, invalid citation, tool error or runtime error |

Do not count hidden reasoning tokens as visible answer throughput. Show full
answer latency as the main cross-model measure because tokenizers and reasoning
strategies differ. Mark truncated outputs as incomplete, not fast successes.
If GPU fallback occurs, label and retain the CPU result separately; never rank
it as a successful GPU run.

Perform one warm-up and three measured warm runs per fixture. Show the median
and range, number of completed samples and whether the process was freshly
loaded. Do not claim a cold disk-cache measurement without controlling that
cache; never drop the system-wide page cache. Rotate candidate order in detailed
comparisons to reduce thermal/order bias. Record power mode and background load
when available so a later rerun can be interpreted.

Quick comparison uses each model's published Pearl profile. Detailed comparison
adds a shared 4K context where compatible, model-specific reasoning budgets, and
selected larger contexts. Record the exact settings with every result; compare
only equivalent workload groups. Context or generation budgets must not be
silently reduced to make a model appear faster or fit in memory.

## CPU and GPU configuration search

Start with the runtime's automatic thread choice. For detailed CPU comparisons,
derive a small candidate set from the process's allowed CPUs and available
topology: a lower thread count, physical-core count, and allowed logical-CPU
count, with duplicates removed. Preserve a user-entered count as another
candidate. Do not assume that every logical thread improves performance.

For GPU comparisons, use discovered compatible devices and verified offload.
Keep one device per run initially, matching current Pearl behavior. Compare CPU,
automatic offload and the user's explicit layer/memory choices. Record shared
memory and unknown device-memory information instead of fabricating measurements.

Present available memory and estimated requirements before a run. These are
advisory; do not reintroduce fixed model-size, CPU-thread or RAM ceilings. The
user may cancel, skip a candidate or proceed with a chosen configuration.
An allocation failure or OS termination must yield a failed result and allow the
remaining candidates to continue. A crash must not silently select another model.

## Results and recommendations

Show model, quantization, actual compute backend, threads, context, median first
answer time, median completion time, peak RAM and fixture pass count. Allow
sorting by response time and memory. Expand a row to inspect sample answers,
errors, runtime identity, measurement spread and exact configuration.

Offer **Fastest successful**, **Lowest memory**, and **Balanced** suggestions.
Exclude incompatible, incomplete or failed runs from successful recommendations.
Use successful-answer latency and memory to identify tradeoffs; do not hide them
inside an unexplained aggregate score. Balanced should prefer a configuration
with comparable latency and lower resource use, using a documented tolerance
that exceeds measurement noise. If results are inconclusive, show that outcome.

Fixture checks establish tool/format compatibility and limited factual behavior.
They do not establish general intelligence or answer quality. Include a small
human-reviewed question set and sample-answer previews, and let users make the
final choice. A model's developer benchmarks are context, not measurements of
the user's device.

## Implementation sequence

1. **Measurement and runner:** add `src/agent/benchmark.zig` with a cancellable
   sequential runner, fixture provider, runtime events, timing/token accounting,
   memory sampling and structured outcomes. Add a headless test driver for
   deterministic scenarios. Reuse runtime cleanup and GPU recovery behavior.
2. **Result storage:** add a versioned local result schema under Pearl's XDG
   state directory. Store model hash, runtime fingerprint/version, workload
   revision, CPU/OS/runtime architecture, relevant CPU features and affinity,
   GPU/driver identity when available, settings, power mode and measurement data.
   Write atomically; keep interrupted runs identifiable. Provide delete/export
   controls. Keep fixture answers local and do not store private conversation data.
3. **Settings workflow:** add candidate selection, explicit downloads, quick and
   detailed modes, progress, cancellation, results, sample answers and draft-only
   configuration adoption. Keep completed results visible when another run fails.
4. **Recommendations:** implement transparent filtering and comparison after
   enough samples complete. Mark results stale after changes to model/runtime,
   hardware/driver, fixture revision or relevant settings. Older results remain
   inspectable but must not masquerade as current measurements.
5. **Qualification:** run native UI and process-lifecycle tests, then real-model
   comparisons on representative older/newer x86 CPUs and AArch64, plus supported
   discrete and shared-memory GPUs. Publish measured configurations with results.

## Acceptance criteria

- A default CPU run compares selected installed models without contacting a
  search provider, downloading implicitly or modifying saved preferences.
- Selecting a new model and applying it uses the exact model, thread count,
  context and compute settings shown in its result.
- Cancellation during loading, reasoning, generation or a fixture tool call
  promptly stops work, reaps children, releases the lock and preserves prior
  completed results. Closing Settings cannot leave a benchmark running.
- Models larger than 768 MB and processes above 1.5 GiB can complete; thread
  counts above two are preserved throughout Settings, serialization and launch.
- Tests cover CPU/GPU fallback, missing models, checksum failure, incompatible
  runtimes, low available memory, OS termination, timeouts, stale results,
  interrupted persistence, invalid citations and repeat-search reuse.
- Reasoning models are measured through the first visible answer and complete
  answer, with no internal reasoning displayed as final answer text.
- Timing, token and memory units are explicit. Unavailable telemetry is marked
  unavailable; no synthetic estimates are presented as measurements.
- Failed or truncated answers never receive a fastest-successful recommendation.
- Native keyboard interaction, scrolling, cancellation and Apply/Discard work
  at normal and narrow window sizes.
