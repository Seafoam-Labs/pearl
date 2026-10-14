# Launcher assistant

The [GPU and runtime update](ASSISTANT_GPU_RUNTIME_PLAN.md) adds selectable
llama.cpp installations and experimental Vulkan/CUDA execution. See the
[interaction mockups](mockups/assistant-gpu/README.md) and
[validation evidence](../artifacts/assistant/gpu-runtime/README.md).

Pearl's experimental assistant is opt-in and disabled by default. In Settings →
Assistant, choose a local model, explicitly download it, configure a search
engine, enable the assistant and Apply. Type a question in Super+Space and
activate **Ask Pearl**. Pearl opens a
separate native chat window and searches only the selected engine(s). Typing
does not start a model or make a network request.

## Google and other engines

The initial provider is **Google through SearXNG**. Supply the base URL of a
SearXNG instance you choose, enable its Google engine, and permit JSON output.
Pearl sends `engines=google`; it does not bundle or choose a public instance.
**Test connection now** sends the disclosed sample query “Pearl desktop”.
Google is selected by default but the feature is not ready without a configured
connection and downloaded model.

General SearXNG, Brave Search API, and Google's existing-account JSON API are
also available. Default mode uses one engine; all-enabled mode accepts at most
three. There is no silent fallback to another provider. Google JSON API needs
an API key and search engine ID; it is closed to new customers and retires
January 1, 2027. [Google's lifecycle notice](https://developers.google.com/custom-search/v1/overview).

API keys are stored in Secret Service using libsecret, separately from exported
preferences. The session collection is available for temporary keys. An absent
or locked Secret Service reports an error and never falls back to plaintext.
The explicitly configured SearXNG endpoint may use private HTTP; public result
pages require HTTPS and their resolved addresses cannot be private networks.

## Local models and runtime

The initial profile is LFM2.5-350M Q4_K_M, 229,312,224 bytes; Q8_0 is
379,217,632 bytes. Both use immutable publisher revision
`657e078c94084481950a2d555a941481f715536b`, with SHA256 values in
[`model_registry.zig`](../src/agent/model_registry.zig). Interrupted downloads
can resume from `.part` files against that immutable revision; the complete
hash must match before atomic installation. Custom local GGUFs are limited to
768 MB and checked for tool-call compatibility before use. The model license is
linked in Settings; models are not bundled with Pearl. Model/runtime tests use
draft settings and local fixtures. Stop a current answer before testing; Pearl
unloads an idle runtime first and an exclusive session lock prevents a second
inference process. Disable and Apply before removing a managed download.

Build the frontend normally, or by itself:

```sh
zig build build-shell build-agent build-settings
```

Choose **Runtime & acceleration** in Assistant settings:

- **Set up runtime (install if needed)** checks the chosen runtime, then existing
  system/private runtimes. It reuses one with the required capabilities. Otherwise
  it opens a terminal to install `llama-cpp` using `shelly install standard
  --needed` on Devario, or `sudo pacman -S --needed` on Arch and Arch derivatives.
  GPU setup adds `ggml-vulkan` for Automatic/Vulkan or `ggml-cuda` for CUDA;
  CPU setup needs only `llama-cpp`. Existing usable GPU backends are reused.
  These are repository-selected versions, not a hard-coded release. See the
  [Arch runtime package](https://archlinux.org/packages/extra/x86_64/llama-cpp/)
  and [backend packages](https://archlinux.org/packages/extra/x86_64/ggml/).
  Devario is detected before Arch ancestry and always uses Shelly.
  The package manager handles authentication, transaction confirmation, signatures
  and dependencies. No AUR builds, repositories, forced downgrades, database-only
  refreshes or system-wide upgrades are started by Pearl.
  Setup requires foot, kitty, alacritty, konsole or xterm; Arch also needs sudo.
  Complete the terminal prompts, then Pearl rechecks capabilities and selects the
  runtime in the settings draft. **Apply** saves that selection; **Check runtime
  and model now** verifies the model, authentication and tools. Installing a GPU
  backend does not install a driver or guarantee a usable GPU.
  Package installations take effect immediately and survive Discard. Closing
  Settings does not kill an active package transaction. Failed/cancelled installs
  or an incompatible repository version leave the runtime selection unchanged;
  fix the package-manager error or update the repository and retry setup.
- **System installation** searches `/usr/bin/llama-server`, then
  `/usr/local/bin/llama-server`, and resolves the actual executable.
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
searches. Required capabilities must pass even for an unlisted release. Changed
executable/model metadata invalidates a loaded profile; full checks run on each
new load. There is no persistent compatibility cache across driver/library
updates. Runtime changes during a check are rejected.

Build the optional inference runtime from an explicitly selected source:

```sh
zig build build-assistant-runtime \
  -Dassistant-runtime-source=/path/to/llama.cpp \
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
build or download llama.cpp. Upstream CMake and the requested GPU development
dependencies must already be available.

The optional [distribution recipe](../packaging/assistant/PKGBUILD) keeps its
own reproducible release/checksum independently of Pearl. It defaults to CPU;
`PEARL_ASSISTANT_BACKEND=vulkan makepkg` or `PEARL_ASSISTANT_BACKEND=cuda makepkg`
builds the corresponding alternative package. A system/custom runtime can be
used without that package. Model download integrity checks remain mandatory.

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
Targets are estimates, not hard VRAM caps. A local CPU/GPU comparison uses a
fixed short prompt and excludes model loading; it sends no search request and
does not change saved settings.

The chat's compute button reports verified offload, CPU fallback or Model
unloaded. Its popover shows the executable, reported build, device/profile and
memory policy. If GPU inference fails, one allowed CPU retry resumes at the last
completed tool boundary. Completed identical tool calls are reused, search
requests are not replayed, and the incomplete draft is replaced. If both attempts
fail after retrieval, the conversation retains the search results. Stop cancels
retries. Applying assistant settings during an answer offers Stop & apply or
Keep editing; an idle runtime unloads before changed settings are used.

The server binds authenticated loopback only, uses no built-in network tools,
and receives fixed arguments and a minimal environment. It has at most two
inference threads and two HTTP workers, and a 4,096-token context by default.
The former virtual-address limit has been replaced: GPU driver mappings can
exceed it even when CPU is selected. Pearl uses a 1.5 GiB host-memory cgroup cap
when delegation is available and monitors resident memory/system headroom.
Without delegation this is best effort; GPU/driver memory is not fully covered
by a host cgroup. The UI and controller add their own overhead. Closing/stopping,
locking, disabling or losing the shell connection cancels work. The runtime
unloads after idle time. There are no inference children after the owning
process exits.

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
search rounds and three result-page reads per turn, with a 90-second deadline.
It preserves the submitted question when fitting history into the context.

`pearlctl assistant status` reports enabled/running/locked/handoff state, selected
runtime/mode and current compute activity without prompt bodies. `show` resumes
the window, `clear` erases session conversations, and `stop` terminates the
assistant and runtime, clearing session history. `cancel` stops the current
answer while retaining the conversation; `release` unloads only an idle runtime
and refuses a busy answer.
These controls use Pearl's existing authenticated session control channel.

## Validation and remaining qualification

Run policy/native tests with `zig build test-agent`. Build the instrumented
frontend with `zig build build-agent-test`. Real-model and private-desktop tests
are in `tests/integration/test_agent_model.py`, `test_agent_ui.py` and
`test_agent_launcher.py`; none downloads models or uses live search credentials.
`test_agent_runtime.py` uses an executable protocol fixture to simulate GPU
enumeration, verified/unverified offload, device failure, version changes and
missing authentication. Its passing results do not establish real GPU support
on a particular driver. Use `test_agent_ui.py --runtime /absolute/llama-server`
to exercise a custom installation with the real local model.
After staging the runtime and supplying an existing model, run the real
launcher/settings test with:

```sh
zig build test-agent-launcher -- --model /path/to/LFM2.5-350M-Q4_K_M.gguf \
    --aqueous /path/to/patched/aqueous
```

The compositor patch was built and exercised in a separate test checkout.
No running desktop or system package was changed. Native screenshots and
acceptance reports are under [`artifacts/assistant`](../artifacts/assistant/).

The 350M model can request a search and summarize returned evidence, but it can
omit citations, answer before searching, or produce misleading follow-ups.
Pearl bounds tool calls, requests one correction, rejects unknown citations,
and shows ordinary results when the model cannot produce a valid cited answer.
Citation-ID validation does **not** prove that the answer is supported by the
source. The plan's 100-question human-reviewed evaluation and low-end 6 GB
hardware qualification remain required before describing this as reliable on
all supported CPUs.

Implementation status and measured test results are recorded with the private
test artifacts; source availability, unit-test success and a single real-model
round trip are not a model-quality certification. AArch64 and older non-AVX2
hardware require separate builds and measurements.

Physical Vulkan/CUDA, AMD/Intel shared-memory behavior, delegated cgroup pressure
and independently packaged upstream versions still need qualification. The
current environment has no GPU device nodes. Reported CPU measurements and
simulated GPU recovery tests must not be presented as GPU performance evidence.

The initial implementation uses native GTK controls with English assistant
copy, a History button that cycles session conversations, and a private
parent-child activation channel. Broader translation/accessibility/scaling
qualification, the 100-question supported-answer evaluation, live paid-provider
checks and Q8_0/AArch64/older-CPU qualification remain release work. The Q4
fixture tests establish the tool and UI flow, not broad answer reliability.
