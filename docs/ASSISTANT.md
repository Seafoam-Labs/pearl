# Launcher assistant

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
linked in Settings; models are not bundled with Pearl. To run the explicit
model compatibility test or remove a download, first Apply with the assistant
disabled and no pending draft. This prevents a second inference process.

Build the frontend normally, or by itself:

```sh
zig build build-shell build-agent build-settings
```

Build the optional inference runtime separately:

```sh
zig build build-assistant-runtime
# Or reuse the exact release source archive offline:
zig build build-assistant-runtime -Dassistant-runtime-archive=/path/to/llama.tar.gz
```

The Zig build target verifies the archive SHA256 and builds **llama.cpp v0.6.0**,
commit `d81235049384534c167caea52b85a694f6103d14`. It stages the executable,
CPU backends, SONAME libraries and pin manifest under
`zig-out/libexec/pearl/assistant`, with `$ORIGIN` library lookup. No build or
runtime download occurs when the assistant is disabled. Distribution packaging
is in [`packaging/assistant/PKGBUILD`](../packaging/assistant/PKGBUILD); install
that optional package alongside Pearl. End users do not compile models.

The server binds authenticated loopback only, uses no built-in network tools,
and receives fixed arguments and a minimal environment. It has at most two
inference threads and two HTTP workers, a 4,096-token context by default, and a 1.5 GiB virtual-address
limit. The UI and controller add their own memory overhead. Closing/stopping,
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

`pearlctl assistant status` reports enabled/running/locked/handoff state without
prompt bodies. `show` resumes the window, `clear` erases session conversations,
and `stop` terminates the assistant and its runtime, clearing session history.
These controls use Pearl's existing authenticated session control channel.

## Validation and remaining qualification

Run policy/native tests with `zig build test-agent`. Build the instrumented
frontend with `zig build build-agent-test`. Real-model and private-desktop tests
are in `tests/integration/test_agent_model.py`, `test_agent_ui.py` and
`test_agent_launcher.py`; none downloads models or uses live search credentials.
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

The initial implementation uses native GTK controls with English assistant
copy, a History button that cycles session conversations, and a private
parent-child activation channel. Broader translation/accessibility/scaling
qualification, the 100-question supported-answer evaluation, live paid-provider
checks and Q8_0/AArch64/older-CPU qualification remain release work. The Q4
fixture tests establish the tool and UI flow, not broad answer reliability.
