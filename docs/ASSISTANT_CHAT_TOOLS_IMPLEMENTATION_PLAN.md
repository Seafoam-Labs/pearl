# Conversational assistant and local tools implementation plan

## Status and scope

**Phases 1–7 implemented.** Implementation
code and appropriate unit tests must be Zig; Python may be used for
integration/validation harnesses.

`src/agent/controller.zig` retains its conversational system rules for every turn,
adds evidence guidance after current-turn retrieval, and gates tools on runtime
qualification. Direct answers no longer trigger host-forced search or mandatory
citations. The explicit search instruction in `src/agent/model_check.zig` is a
local tool compatibility probe, separate from chat health and conversation policy.

Only `search_web` and `read_page` exist for web access. Local tools
(`search_files`, `read_file`, `create_file`, `delete_file`, `find_applications`,
`open_application`) are gated behind explicit opt-in folder grants and native
user confirmation for mutations. Deterministic tests verify controller/protocol
contracts; real-model response quality and small-model tool-selection reliability
still need qualification. Prompt sizing uses the runtime's actual chat template
and tokenizer.

## Target behavior

- Normal conversation, explanations, writing, and coding help work without search,
  sources, or a configured search provider. No network request for ordinary chat.
- Search is optional and appropriate for current facts, verification, or an explicit
  request; failures do not prevent a useful, honestly qualified response.
- The assistant can search permitted filesystem locations, read files, create new
  files, delete files only after explicit user confirmation, and open applications
  requested by the user.
- Tool calls are proposals. Zig host policy, not prompt text or model assertions,
  decides which operations may execute. There is no general shell/command tool.
- Local data stays local by default. Reading a file never grants permission to
  transmit its contents, sensitive filenames, or paths in a web search.

## Existing integration points

| Area | Current code and required change |
| --- | --- |
| Conversation/tool loop | `src/agent/controller.zig`: remove forced first-turn search, no-source rejection, and universal citation requirement; generalize the two-tool executor. |
| Model transport | `src/agent/llama.zig`: replace static two-tool JSON and all-or-nothing tool flag with the enabled tool registry. |
| UI and lifecycle | `src/agent/application.zig`: add tool activity, pending confirmation, and neutral completion states; preserve generation/cancellation guards. |
| Preferences | `src/agent/config.zig`: add opt-in capabilities and filesystem grants with migration defaults that grant no new local access. |
| Private shell channel | `src/agent/protocol.zig`, `src/agent/host.zig`: evaluate a narrow authenticated app-launch request/reply, not arbitrary command transport. |
| Application discovery/launch | `src/desktop/apps.zig`, `src/desktop/dock.zig`: reuse catalog and desktop-ID launch patterns, including activation context; factor shared Zig code if necessary. |
| Compatibility and benchmarking | `src/agent/model_check.zig`, `src/agent/benchmark.zig`: separate conversational, web-tool, and local-tool capability qualification. |

## Phase 1 — Remove search-only enforcement (implemented)

- [x] Always start each turn with the persistent conversational system prompt.
      Add evidence-answer guidance only when relevant evidence is supplied; never
      replace the base rules or make prior sources impose citation requirements
      on an unrelated follow-up.
- [x] Remove `corrected_search`, the forced-search correction, and the host fallback
      that searches the user's question when the model answers directly.
- [x] Accept direct answers with no sources. Keep provider validation at the web
      tool boundary; audit config/runtime validation so disabled or missing web
      providers do not block otherwise valid chat.
- [x] Replace the overloaded `Answer.summarized` contract with explicit outcomes
      for completed answers, partial answers, cancellation, and errors. Update UI
      status text instead of reporting every response as a search summary.
- [x] Stream non-search answers, with incomplete drafts and explicit failure
      outcomes rather than a source-dependent `live` gate.
- [x] Validate supplied citations against actual source records. Require citations
      for source-backed factual answers, not every message. Syntax validation can
      reject unknown IDs but cannot prove claim support; do not describe it as
      factual verification. Preserve host-owned source links.
- [x] Make tool failures structured results the model can explain or recover from,
      while cancellation, revoked permissions, and policy denial remain enforced.
- [x] Retain complete recent messages within a measured token budget rather than
      clipping every question to 1,000 bytes and answer to 1,800 bytes. Preserve
      tool-call/result groups and important action outcomes. Include actual tool
      schemas, chat-template overhead, and completion reserve in budget checks.
- [x] Revisit the 2,048-byte question limits across the UI, intent, and protocol
      together for practical writing/coding requests; retain explicit size limits.
- [x] Split runtime health/chat support from tool qualification. A model that can
      converse but fails tool checks should be usable in clearly labeled chat-only
      mode, never allowed to execute guessed or malformed tool requests.

Acceptance: greetings, explanations, creative writing, and a post-search “thanks”
complete without mandatory citations; fresh-chat cases issue zero search requests.
A current-facts query can search and cite, and a provider failure is explained
without fabricating current facts. Run regression cases with deterministic runtime
fixtures before real-model evaluation.

Implementation details: question limit is 32 KiB; protocol frames are bounded at
512 KiB to allow JSON escaping and configuration. `/apply-template` includes the
same messages/tools as completion; `/tokenize` measures that prompt with special
tokens parsed, then the configured answer budget plus 32 tokens is reserved.
Old historical pairs are pruned whole; active tool-call/result groups are never
split. Current search/read success requires citations, but earlier sources alone
do not. Failed/empty retrieval can be explained without citations. Citation checks
are deliberately syntactic and cannot classify the truth of factual claims.

Validation covers native offline conversation/runtime fixtures, the private
runtime/device integration suite, and the benchmark fixture suite. Benchmark
workload revision is now 2; older comparison results are marked stale. Tests do
not establish real-model quality or physical GPU support. Later phases will add
permissions/revocation beyond today's page-reading toggle and tool allowlist.

## Phase 2 — Typed tool registry and host permissions (implemented)

- [ ] Introduce a shared Zig registry defining schemas, availability, argument
      validation, permission class, limits, execution, and structured results.
      Generate advertised schemas and capability text from the enabled registry.
- [ ] Reject unknown tools, extra/invalid arguments, oversized values, stale
      resource handles, and calls to tools not advertised for that turn.
- [ ] Separate web, local read/search, file creation, deletion, and app-launch
      capabilities. Filesystem permissions are explicit root grants with read,
      create, and delete rights, not ambient access to the user's whole home.
- [ ] Add a native folder-grant flow and permission revocation. An outside-root
      request must fail closed and offer a user-controlled grant, not silently
      broaden access. No privilege escalation or access to other users' files.
- [ ] Use structured tool outcomes (`ok`, `denied`, `not_found`, `ambiguous`,
      `pending_confirmation`, `cancelled`, `failed`) with bounded data and clear
      error details. Only confirmed executor results establish success.
- [ ] Bound calls, output bytes, traversal, and execution time per turn; keep
      cancellation responsive. Preserve completed results across inference retries.
      Side effects must never be repeated just because inference retries on CPU.
- [ ] Treat files, filenames, web content, and all tool output as untrusted data.
      None can approve actions, expand grants, or trigger privileged operations.
- [ ] Block silent local-to-web disclosure. Any proposed export of local material
      needs host-mediated review of the exact outgoing data and explicit consent;
      prompt-only warnings are not an enforcement boundary.

## Phase 3 — Filesystem search and reading (implemented)

Proposed tools (names/schemas are not implemented yet):

| Tool | Inputs | Contract |
| --- | --- | --- |
| `search_files` | granted root ID, query, filename/content mode, optional bounded cursor | Return bounded matches, opaque file IDs, display paths, and truncation status. |
| `read_file` | file ID, bounded offset/length or line range | Return bounded text with path, range, version, and truncation metadata. |

- [ ] Start with local filename search and bounded text-content search. Semantic
      indexing may augment results later, but is not required, does not broaden
      grants, and stale indexed hits must be revalidated before reading.
- [ ] Enforce directory-handle-relative path resolution beneath the granted root;
      reject traversal and symlink escapes. Define a no-follow policy initially,
      and fail closed if equivalent race-resistant enforcement is unavailable.
- [ ] Read only regular files; reject devices, sockets, FIFOs, pseudo-filesystems,
      oversized requests, and unsupported encodings/binary formats. Do not execute
      or render active content. Skip hidden/sensitive credential locations by
      default and make any exception explicit in the permission UI.
- [ ] Bound directory depth, matches, total bytes, and elapsed time. Avoid following
      mount boundaries by default and disclose skipped/unreadable entries.
- [ ] Return source metadata for local references separately from web citation IDs.
      Do not claim a complete search when limits or permissions restricted it.

Acceptance: permitted fixtures can be found/read; traversal, symlink replacement,
revoked roots, oversized files, binary files, special files, and cancellation do
not leak data or hang the process.

## Phase 4 — Creating files (implemented)

Proposed `create_file(parent_id, name, content)` creates a new regular text file
within a create-enabled root. It is not an overwrite/edit/execute tool.

- [ ] Require user intent to create a file. Initially show a native preview with
      exact destination, size, and content and an explicit Create action, making
      authorization host-verifiable rather than trusting the model's intent claim.
- [ ] Validate the parent handle and a single filename component. Refuse existing
      destinations, symlink targets, executable permissions, and automatic parent
      directory creation. Prefer an explicit conflict result over overwriting.
- [ ] Publish complete contents with no-replace semantics, restrictive permissions,
      and cleanup on error/cancellation. Use bounded UTF-8 content initially.
- [ ] Do not allow creation of autostart entries, executable launchers, or other
      execution-triggering configuration through an unrestricted generic write.
      Keep protected locations outside ordinary create grants.
- [ ] Report the actual created path only after success. Associate execution with
      a host action ID so duplicate calls/retries cannot create multiple copies.

Acceptance: existing data is never overwritten; denial creates nothing; interrupted
writes do not leave a misleading completed file; approved creation is performed once.

## Phase 5 — Deletion with mandatory explicit confirmation (implemented)

Proposed `delete_file(file_id)` prepares a deletion request; it **cannot execute
without a separate native user confirmation for that exact operation**.

- [ ] Show a native confirmation card/dialog containing the exact display path,
      file type, identity/version, and whether the operation moves to Trash or
      permanently deletes. Use explicit Cancel and Move to Trash/Delete buttons;
      cancellation is the safe default. Never render filenames as active markup.
- [ ] Prefer recoverable Trash where available. If Trash is unsupported, do not
      silently fall back: require a new explicitly permanent-deletion confirmation.
- [ ] Bind a single-use host-owned approval to the conversation generation, tool
      call, exact target identity/version, and operation. Model arguments such as
      `confirmed: true`, a model-written “yes,” prior approvals, and document text
      are never authority. The initial “delete this” request still gets a preview.
- [ ] Revalidate permissions and identity immediately before mutation; invalidate
      approval if the target, arguments, or grants changed. Specify and test the
      platform's race-resistant deletion strategy; do not assume a `stat` followed
      by pathname deletion is sufficient. Fail closed if target identity cannot
      be maintained through execution.
- [ ] Pending approval is a resumable state, not a blocking GTK worker or an
      inference call waiting indefinitely. Pause inference deadlines while waiting;
      expire approvals after a bounded period. Stop, clear, conversation changes,
      shutdown, and permission revocation invalidate pending requests.
- [ ] Initially support individual regular files only. No recursive directories,
      globs, or bulk deletion; later batches need an exact reviewed target list.
- [ ] Record truthful operation outcomes. If cancellation races with a completed
      deletion, report that completion rather than claiming nothing happened.
      Unknown outcomes must not be automatically replayed after restart.

Acceptance: zero deletions before confirmation; denial/expiry/stale approvals do
nothing; replay cannot delete twice; target substitution invalidates approval;
Trash failure never becomes unapproved permanent deletion.

## Phase 6 — Open requested applications (implemented)

Proposed `find_applications(query)` returns installed catalog IDs and display names;
`open_application(application_id)` opens one resolved application.

- [ ] Use Pearl's installed application catalog and desktop-entry launch APIs.
      Accept only resolved IDs, never a model-supplied executable, command line,
      shell snippet, arbitrary desktop file, or URL scheme.
- [ ] Require a user request to open an application. Initially use a native Open
      action showing the resolved app to make intent explicit; ambiguous matches
      present a user choice instead of guessing or opening several apps.
- [ ] Reuse the private shell/agent channel if needed for activation and existing
      launch attribution. Bind any launch authorization to the chosen app; do not
      expose a new unauthenticated IPC endpoint.
- [ ] Limit the first version to opening apps without arguments, files, URIs,
      terminal commands, or desktop actions. Those would require separate policy.
- [ ] Return launch failure accurately. A successful launch API call means the
      launch was requested, not that a window appeared or a task completed.
      Reuse an existing window only through established Pearl activation logic.
- [ ] Never automatically retry a possibly completed launch on inference recovery.

Acceptance: requested installed applications launch once; ambiguous, stale, denied,
invalid-ID, and failed-launch cases are handled without arbitrary command execution.

## Phase 7 — UI, qualification, and rollout (implemented)

- [ ] Show a compact tool activity timeline with target, pending/running/completed
      status, denial/error details, and confirmation controls. Never portray proposed
      actions or streaming claims as completed actions.
- [ ] Add permission management and capability indicators in Settings. Keep local
      tools opt-in and preserve existing preferences without granting new rights.
- [ ] Update prompts to describe enabled local tools only when executors and host
      policy ship. Add mandatory deletion-confirmation and untrusted-file rules;
      leave enforcement in Zig regardless of what the model produces.
- [ ] Extend compatibility checks and benchmarks for direct conversation, optional
      search, each local tool, malformed calls, prompt injection, and multi-turn
      intent. Qualify the 350M model separately from larger models and expose
      chat-only/tool-limited fallback when reliability is insufficient.
- [ ] Add Zig policy/state-machine tests and deterministic runtime fixtures. Native
      UI integration tests must drive actual approval/denial controls using private
      HOME/XDG roots, fake desktop entries, and temporary files only.
- [ ] Test GPU/CPU retry after each side effect, duplicate call IDs, changed call
      arguments, crash/restart, close/clear/switch while approval is pending, races,
      revocation, and log redaction. Never log file contents, credentials, or full
      private paths by default; user-visible outcomes can show the chosen target.
- [ ] Update `docs/ASSISTANT.md`, tests, and benchmark expectations for the new
      response and capability contracts. Begin with `zig build test-agent`, then
      build the frontend using `zig build build-agent-test`, then run relevant
      private-desktop/model suites with explicitly supplied existing models.

## Delivery order and release gate

1. Conversational controller and optional web search, independently releasable.
2. Typed registry, grants, and resumable confirmation lifecycle.
3. Read-only filesystem tools.
4. Confirmed create and installed-application opening.
5. Confirmed deletion after adversarial identity/approval testing.

Do not enable local mutations until authorization, cancellation, identity checks,
and retry/idempotency tests pass. Do not claim ChatGPT/Claude-level reasoning from
prompt changes alone, and do not treat a passing tool-schema test as evidence of
reliable real-model behavior.
