# Assistant GPU and runtime update plan

Status: experimental implementation added, October 14, 2026. See the
[current setup and behavior](ASSISTANT.md) and
[qualification report](../artifacts/assistant/gpu-runtime/README.md). Physical GPU,
driver/cgroup pressure and distribution-version qualification remain release
gates. The decisions below retain the design intent and acceptance criteria.
All Pearl implementation and build orchestration
remain Zig; llama.cpp remains the external C/C++ inference dependency.

Implementation refinements: runtime checks repeat on each new load instead of
persisting results without reliable driver/library fingerprints. Device matching
uses backend/description/capacity and rejects duplicates because upstream's
portable listing lacks physical UUIDs. Host-memory monitoring replaces the old
address-space limit in CPU mode too, since GPU-capable binaries may map drivers
before deciding where to execute. These limitations are exposed in setup docs
and must be included in hardware qualification.

Allow users to run the assistant on CPU or a supported GPU and choose their own
compatible `llama-server`. Remove the application's requirement for llama.cpp
v0.6.0 and its exact commit/hash manifest. Accept runtimes by the behavior Pearl
needs, with version information retained for diagnostics and testing.

The assistant stays opt-in. Super+Space questions still open a small floating
conversation, search the configured engines and stream a local summary with
sources. Bing's public RSS search is the default provider and needs no account
or server setup. Searches run only after an explicit Ask or connection test.

## Mockups

[Mockup gallery](mockups/assistant-gpu/README.md) contains editable SVGs and PNG
previews of four proposed states:

1. [Runtime and acceleration settings](mockups/assistant-gpu/settings.png).
2. [Runtime selection and compatibility checks](mockups/assistant-gpu/runtime.png).
3. [Launcher question and floating GPU conversation](mockups/assistant-gpu/conversation.png).
4. [GPU recovery and shared memory settings](mockups/assistant-gpu/recovery.png).

## Product decisions

| Setting or behavior | Proposed decision |
| --- | --- |
| Enable assistant | Off by default; no inference or GPU probing while disabled except an explicit local compatibility test. |
| Initial compute mode | CPU for new and migrated preferences. GPU use requires selecting Automatic or GPU and applying. |
| CPU | Explicitly disable all device offload, including auxiliary operation offload where supported. Keep the existing small model and resource profile. |
| Automatic | Choose one compatible GPU with adequate memory, otherwise use CPU. CPU fallback is inherent in this mode and explained in Settings. |
| GPU | User selects one device and backend. A separate “Use CPU if GPU is unavailable” setting defaults on; turning it off makes failures stop for user action. |
| Runtime source | System installation, optional Pearl runtime package, or custom executable. Fresh installs start with System; upgrades preserve the existing private runtime. |
| Version policy | No required release, commit, filename hash, or Pearl manifest. Capability and model checks determine compatibility. |
| Linux backends | CPU, Vulkan and CUDA in the first release; HIP/ROCm follows after separate hardware qualification. |
| Models | Keep LFM2.5-350M Q4_K_M, Q8_0 and compatible local GGUF selection. GPU selection does not change or download the model. Existing model integrity checks and import size limit remain. |
| Conversation | Same floating window and session-only history. Show the actual active compute device, including CPU fallback. |
| Scope | One owned local server, one model, one selected GPU. Remote inference servers, multi-GPU splitting and larger-model policy are separate work. |

Automatic prioritizes a saved, validated device; otherwise try a discrete GPU
before an integrated GPU, with CUDA preferred for NVIDIA when both CUDA and
Vulkan pass. Use a stable ordering to break ties. This is a proposed selection
policy, not a claim that GPU is always faster. With a 350M model, launch overhead
and memory transfers can outweigh acceleration. Offer an explicit local speed
comparison after compatibility succeeds; never benchmark on launcher typing.

## Existing code that must change

| Current constraint | Implementation consequence |
| --- | --- |
| `src/agent/runtime.zig` only resolves the sibling private executable and requires an exact `runtime.json` | Introduce runtime discovery and a compatibility result; make provenance informational. |
| Fixed `--gpu-layers 0` and minimal environment | Build arguments from a validated compute profile and a bounded backend environment policy. |
| Hard 1.5 GiB `RLIMIT_AS` | Replace the memory policy for GPU execution; address space is not resident RAM or VRAM. |
| Runtime identity includes only model, context and CPU threads | Include resolved runtime identity, backend, device, offload and memory policy. |
| Build recipe downloads one fixed source archive and disables GPU backends | Accept caller-selected sources and selectable backend builds; keep normal Pearl builds independent. |
| Private library filenames are fixed to one upstream layout | Stage the selected build's actual install outputs and required libraries; verify relocation. |
| Settings expose models, providers and CPU resources | Add a Runtime & acceleration section with compatibility, device and recovery controls. |

## Runtime selection without a version lock

**System installation** resolves `llama-server` from trusted system executable
directories and displays its absolute resolved path. Do not search the working
directory or execute a command string. User-local installations use the custom
file chooser. **Pearl runtime package** selects the existing private install
location. **Custom executable** accepts an absolute executable file, including
paths containing spaces. Resolve symlinks and show the target; never invoke a
shell or accept extra command-line text.

A chosen source never silently switches to a different executable. If it is
missing or incompatible, present Choose runtime and Retry. CPU fallback changes
the compute profile within the chosen runtime; it does not select another
installation. Missing `runtime.json` is valid for system/custom builds. Optional
package provenance is bounded, treated as descriptive data and cannot override
the results of checks.

### Compatibility contract

Add `src/agent/runtime_probe.zig` with bounded subprocess probes and a structured
result: executable identity, reported version, supported options, available
devices, checked model/profile, missing capabilities and last test outcome.
Suggested initial limits are five seconds per metadata probe, 256 KiB per output
stream and a cancellable 90-second model test. A timeout means “Check timed out”,
not a claim that the hardware or version is permanently unsupported.

1. Inspect executable metadata and collect version/help output. Check options
   needed for loopback binding, API authentication, fixed worker/context limits,
   model selection and template handling. Enumerate devices only when requested
   in Settings or when a submitted question uses Automatic/GPU.
2. Map supported options through a small typed adapter. Optional flags absent
   from older versions must not make those versions fail by themselves. For
   example, a runtime predating built-in agent tools needs no disabling flag;
   accept it only through an adapter with a verified safe behavior profile.
   Unknown semantics fail with an explanation rather than guessed arguments.
3. Start one private server with the selected local model. Verify readiness,
   authenticated requests, rejection of unauthenticated inference, token
   counting, streamed chat, and a bounded tool-call/tool-result continuation.
   Use a synthetic local search fixture; the check never queries Google or
   another provider. Run model checks for managed models as well as imports
   when the runtime changes.
4. In GPU mode verify successful inference and evidence of actual offload to
   the selected device. A listed GPU or successful server startup is not proof
   of GPU execution. Report CPU execution or “Acceleration unverified” when
   evidence is unavailable; do not display a GPU success badge.

Keep metadata checks separate from full model compatibility. Settings can show
“Runtime found; model test required” without loading weights. **Check now**
explicitly runs the local test; first submitted use may run it automatically.
Testing and normal inference share one process owner. Disable testing while an
answer is active; an idle model must unload before a test starts.

Cache successful checks under XDG cache, separately from preferences and secrets.
Key them by resolved binary digest, relevant backend library identities, model
digest/template, requested profile, device and driver identity where available.
If backend/driver identity cannot be established, use a session-only result and
repeat the relevant startup checks. Re-stat before launch and discard results
when an executable changes during a test. Cached success never skips startup
health/authentication checks or proves that GPU memory is still available.

Runtime upgrades trigger “Runtime changed — checking compatibility” on next
use. Do not replace a running executable mid-answer. On failure retain the
question, conversation and retrieved evidence and offer another installed
runtime. An unlisted version that passes is accepted without an override or
warning dialog. Publish tested build identifiers as advisory evidence, not an
allowlist. Pearl does not automatically download or upgrade llama.cpp.

## GPU selection and memory policy

Upstream documents Vulkan, CUDA and HIP build options. Its server exposes
device enumeration, device selection, GPU layer counts and single-device split
mode; newer builds also expose memory fitting options. Treat these as
capabilities to discover, since installed releases differ.
[Upstream build guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md),
[server options](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).

Add `src/agent/compute.zig` to normalize devices and construct the launch profile.
Use backend plus a stable device identifier when available; never persist a bare
enumeration index. Match stable PCI/UUID information, deduplicate a physical GPU
exposed by multiple backends and translate to the current runtime's device name
at launch. If stable matching is unavailable or ambiguous, reselect explicitly
instead of assuming index zero still identifies the same device.

For the first release, a GPU profile selects exactly one device and disables
multi-device splitting. Offer automatic layer offload and an Advanced manual
layer count, bounded by model metadata. Preserve the configured context length
and concurrency. Do not silently shrink context to fit. Disable implicit fitting
where supported unless the adapter has verified that it respects these settings.

Use a proposed default GPU memory reserve of the greater of 512 MiB or 20% of
device capacity, plus an optional user target for assistant GPU memory. Estimate
weights, cache and working buffers before loading; use a verified runtime fitting
adapter when available, otherwise estimate a conservative layer count. These
are planning targets, not hard VRAM isolation. Display estimates as estimates.
If reliable available-memory information is absent, Automatic stays on CPU;
manual GPU use requires a successful explicit test. Do not enable driver memory
oversubscription as a hidden default.

Integrated GPUs share system RAM. Show “Shared system memory” instead of adding
it to a separate VRAM total. Reserve desktop headroom and evaluate combined
system pressure. A GPU must not make the 6 GiB system target worse through
unbounded shared allocations.

Remove the fixed `RLIMIT_AS` from GPU children: driver virtual mappings can exceed
it without consuming that amount of physical RAM. Use a dedicated cgroup v2
memory boundary when delegation is available, plus process-group accounting and
memory-pressure monitoring. Initially target at most 1.5 GiB of accounted host
memory for inference, with UI/controller overhead measured separately. Without
delegation, label the policy best effort and stop on sustained pressure or
budget excess. GPU memory and some driver allocations need separate monitoring;
a cgroup limit is not a VRAM limit. Calibrate thresholds on real machines before
release. Keep the existing CPU limit until its replacement is qualified.

Preserve explicit small thread/HTTP worker counts, one inference process, idle
unload, cancellation, child reaping and shell/lock lifetime handling. Audit the
environment allowlist for driver discovery and explicitly selected device
visibility; keep provider credentials and inherited `LLAMA_ARG_*` overrides out
of the child. Never inherit arbitrary loader overrides to make a build work.

If GPU loading or inference fails, reap the child and attempt CPU once when the
mode allows it. Restart the incomplete assistant turn from its last completed
tool boundary, reuse retrieved evidence and deduplicate tool calls. Do not
append a restarted answer to a partial draft or repeat paid search requests.
Stop cancels both the failed attempt and any scheduled retry. If CPU also fails,
retain the transcript and show a recoverable error. Refresh memory estimates
before each fresh load; no endless GPU/CPU retry loop.

## Preferences and native UI

Extend `src/agent/config.zig` with nested settings; names below are proposed API
names, not fields currently accepted by Pearl.

| Field | Values and default |
| --- | --- |
| `runtime.source` | `system`, `packaged`, `custom`; fresh default `system` |
| `runtime.executable` | Absolute path required only for `custom` |
| `compute.mode` | `cpu`, `auto`, `gpu`; default `cpu` |
| `compute.backend` | `auto`, `vulkan`, `cuda`; later `hip` |
| `compute.device_id` | Empty for Automatic; a validated device identity for explicit GPU |
| `compute.offload_layers` | `null` for automatic; bounded integer for Advanced |
| `compute.gpu_memory_target_mib` | `null` for automatic; positive target validated against device information |
| `compute.allow_cpu_fallback` | `true`; editable in GPU mode, implied in Automatic |

Retain existing CPU threads, context, response and idle-unload preferences.
Capability observations and transient failures are not persisted as user intent.
Migrate existing assistant objects lacking runtime fields to `packaged` + `cpu`,
preserving the original installation. A new preferences document or one without
an assistant object gets `system` + `cpu`. Migration must not run discovery or
enable the assistant. Reject invalid combinations with field-level explanations.

In `src/settings/assistant_view.zig`, add **Runtime & acceleration** beside the
existing model/search settings. Display source, resolved executable, reported
version, Check now, compute mode, device/backend and CPU fallback. Hide advanced
memory/layer controls behind a disclosure. Retain Apply/Discard semantics.
Selecting a runtime file only edits the draft; Test executes the chosen file as
the user, with a clear “Runs a local model test; no web searches” caption.

Apply changes when idle, unloading the old process before a later load. If a
response is active, offer **Stop & apply** or **Keep editing**; do not silently
discard the response. Discard does not restore an unloaded process, but it keeps
the saved settings and conversation. Unsaved test results cannot change the
active inference profile.

In `src/agent/application.zig`, show “Preparing local model”, “Checking runtime”,
“Searching Google” and “Writing answer” as actual activity changes. Use a compact
compute badge with a details popover for backend/device, partial offload and
fallback reason. GPU labels appear only after verification. Idle state says
“Model unloaded” rather than implying a GPU is still allocated. The small window
retains source links, Stop, follow-up input and focus behavior.

Extend `pearlctl assistant status` and the internal protocol with sanitized
runtime/compute status. Do not include prompts, keys, raw environment or full
unbounded runtime logs. UI strings use existing localization, keyboard and
screen-reader conventions; status announcements must not steal input focus.

## Builds and distribution

**Required llama.cpp version: none by number.** Install a system `llama-server`
or choose an upstream build that passes the contract for the chosen model and
device. The old v0.6.0 build remains a CPU regression fixture, not a requirement.
Qualify at least one current upstream release and one independently packaged
build when implementing; record exact tested IDs and results then, without
inventing a tested GPU version in this planning update.

The optional Zig build target should accept either a caller-supplied source tree
or an archive with a caller-supplied SHA256. Require an explicit source; remove
the hardcoded default download. Add a backend option (`cpu`, `vulkan`, `cuda`,
later `hip`) and retain upstream CMake at the dependency boundary. Proposed
invocations, unavailable until implementation:

```sh
zig build build-assistant-runtime \
  -Dassistant-runtime-source=/path/to/llama.cpp \
  -Dassistant-runtime-backend=vulkan

zig build build-assistant-runtime \
  -Dassistant-runtime-archive=/path/to/llama.tar.gz \
  -Dassistant-runtime-sha256=EXPECTED_SHA256 \
  -Dassistant-runtime-backend=cuda
```

Map the backend to upstream `GGML_VULKAN`, `GGML_CUDA` or `GGML_HIP` configuration
as appropriate, and verify the source supports the requested build options.
Distribution recipes still record release versions, source checksums and build
provenance for reproducibility; the application does not enforce those exact
values. A locally modified source tree is labeled as such. This change does not
remove model download hashes or source archive integrity checks.

Update `packaging/assistant/build.zig`, its `PKGBUILD`, optional dependency text
in the main packages and `src/verify_assistant_source.zig` as needed. Avoid a hard
dependency on Pearl's runtime package when a system installation is usable.
Ship backend variants without installing GPU toolkits for CPU-only users. Verify
the staged runtime's actual SONAME dependencies and backend load paths instead
of copying a fixed list from the old release. Normal Pearl builds and disabled
sessions must not download, build or initialize an inference runtime.

## Implementation sequence and acceptance

| Milestone | Files and work | Completion evidence |
| --- | --- | --- |
| 1. Runtime selection | `config.zig`, `preferences.zig`, new `runtime_probe.zig`, `runtime.zig`; migration and removal of manifest equality | Legacy preferences retain CPU/private runtime; two different compatible builds work without the pin manifest; missing required capabilities fail clearly. |
| 2. Compute and budgets | New `compute.zig`, `runtime.zig`, process ownership and memory monitoring | CPU reliably excludes GPU; one selected Vulkan/CUDA device actually offloads; driver failure/OOM/cancellation leave no child or retry loop. |
| 3. Native controls and chat | `assistant_view.zig`, `application.zig`, `protocol.zig`, status handling and controller fallback | Draft/test/apply flows match mockups, chat reports actual execution, and fallback reuses search evidence without duplicate provider calls. |
| 4. Portable optional builds | `packaging/assistant/*`, build options, dependency metadata and docs | CPU and GPU source/archive builds relocate successfully; distro/custom runtime selection works; application never checks an exact upstream release. |
| 5. Qualification | Zig tests and existing integration harnesses; physical hardware runs | Matrix below passes with recorded model/runtime/driver IDs, memory and latency. HIP support is added only after its own passing matrix. |

Use Zig fixtures for argument selection, capability parsing, bounded malformed
output, preference migration, changing executable identity, ambiguous devices,
cache invalidation and fallback state transitions. Exercise a fake server for
missing authentication, truncated SSE/tool calls, timeout and cancellation.
Fixtures validate failure handling but cannot certify real GPU execution.

Extend the existing Python integration harnesses only for native UI/session
validation: disabled idle footprint, launcher handoff, settings draft isolation,
runtime replacement, Stop during loading/testing/retry, closing or locking,
and search-provider request counts through a local fixture. Keep the existing
calculator and launcher behavior covered. Test native layout at 320 logical
pixels, 440 × 560 default size, increased text scaling and keyboard-only input.

| Hardware or runtime case | Required observation |
| --- | --- |
| CPU-only 6 GiB machine, small LFM model | Search, summary, tool continuation and follow-ups complete within the qualified memory envelope; record cold/warm latency. |
| Assistant disabled on a 4 GiB machine | No agent/inference process, GPU scan, model load, probe or provider request attributable to this feature. |
| NVIDIA discrete GPU | CUDA and Vulkan tested separately; actual offload, memory release, device preference and desktop responsiveness. |
| AMD and Intel GPUs | Vulkan on each; at least one integrated device with shared-memory accounting and pressure tests. |
| Low VRAM, missing driver, GPU removal | One allowed CPU retry, preserved question/evidence, accurate UI; explicit GPU-only mode stops. |
| Two GPUs or one device exposed by two backends | Stable selection, no accidental multi-GPU load, changed indices handled. |
| Legacy, current release, distribution and custom builds | Behavior-based compatibility, no manifest requirement, version changes invalidate checks, unknown options do not silently weaken isolation. |
| Missing library or incompatible model template | Useful setup error, bounded logs, no search request during compatibility tests. |
| cgroup delegation present and absent | Enforced versus best-effort host memory policy reported honestly; memory pressure stops work in both modes. |

Measure process-tree RSS/PSS, cgroup-accounted memory where available, GPU memory,
system pressure, cold load time and first-token/generation latency separately.
Record requested and actual offload, not just a backend label. A 6 GiB system
target is a qualification goal, not a promise for every CPU, driver or imported
model. GPU acceleration changes execution speed and placement, not the small
model's answer quality; existing factuality and tool-use gates remain required.

Update `docs/ASSISTANT.md` and runtime setup instructions only when each behavior
lands. This plan supersedes the original plan's CPU-only/version-lock decisions
for the proposed update; current setup documentation remains accurate today.
