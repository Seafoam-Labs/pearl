# M6/M7: Agent core and Zed-agent parity

**M6 agent core and the M7 Zed-agent-parity backend/UI are implemented and
validated (targeted).** The backend is a **GTK-free `src/agent` service**
(engine, provider, policy, review, store, thread, tools, context, acp, mcp,
skills, auth, rpc, cancel, host) driven through a host callback boundary; the
native **Agent dock is the fifth persisted panel** (default right, hidden) with
a thread list, streaming transcript, context chips, provider picker, permission
cards, review accept/reject, skills search and cancel. Providers are a
**deterministic offline `fake`**, an **opt-in OpenAI-compatible** HTTP endpoint
(user-supplied `base_url`/API key, no proxy substitution, no secret logs) and
**ACP** external agents. The **ACP v1 JSON-RPC stdio client** negotiates
`protocolVersion: 1` capabilities, runs session new/prompt/update/cancel,
answers permission requests (allow/deny/cancel), routes filesystem reads/writes
through the host (writes through review) and drives terminal callbacks, with
disconnect/malformed-frame safety. The **MCP stdio client** allows read-only
tools and requires approval for writable ones. **Markdown skills** load and
search from workspace roots. Threads persist under
**`$XDG_STATE_HOME/coral/agents`** with **worktree binding**, **checkpoints** and
**wholesale stale-review refusal**; a **denied tool has no side effect**.
Workspaces remain **always trusted by user request** (no consent prompt); tool
permissions and review remain, and this is **not an OS sandbox**.

Targeted validation passed: **agent-core-unit 54, agent-protocol-unit 62, native
agent 9/9, docks 27/27, session-unit 29/29, widgets 218, layout 5/5 and build
pass**. The **full aggregate was not rerun**; hooks-disabled production and
visual gates are pending the parent aggregate. Protocol parity is exercised
against **two fake ACP adapters (echo/edit) and a fake MCP server** under
`tests/fixtures`; **real external adapters are not installed and no real-adapter
parity is claimed**. Remaining limits: the ACP picker's empty argv clean-fails
(real adapter argv configuration is future work), the UI does not rebuild
restored threads (engine restore is covered), host root bind timing, the fake
default script makes no tool calls, and no live provider/network tests were run.
**M8 is next.** This is not full Zed agent parity.

## Architecture: GTK-free backend and host boundary

`src/agent` never imports GTK and links libc only. The embedding application
supplies the `host.Host` callback boundary so the backend can read files, apply
reviewed edits and drive terminals without touching the UI:

- `readFile`, `listDir`, `search` — read-only host access.
- `writeFile` — **only invoked for accepted reviews or checkpoint reverts**.
- `terminalSpawn`, `terminalWait`, `terminalKill` — host-owned PTY/subprocess
  execution (`terminalKill` must be idempotent).
- `gitDiff`, `diagnostics` — rendered context sources.
- `log` — optional structured sink; the backend **redacts secrets before
  calling it**, and hosts must still treat messages as untrusted.

A missing callback is reported as `error.Unsupported` rather than crashing.
Callbacks may be invoked from agent worker threads; the host marshals onto its
own main loop. Module responsibilities:

| Module | Responsibility |
| --- | --- |
| `engine.zig` | Public backend API; provider streaming, ACP/MCP clients, tool policy, review/checkpoints, cancellation, worktree binding, atomic persistence |
| `provider.zig` | Provider registry: deterministic `fake` and opt-in `openai` |
| `policy.zig` | Per-tool allow/deny/ask decisions; denial has no side effect |
| `review.zig` | Multi-file proposals, base-revision checks, checkpoints, stale refusal |
| `store.zig` | Atomic JSON thread persistence under XDG state |
| `thread.zig` | Thread data model and explicit state machine |
| `tools.zig` | Tool schemas advertised to providers; worktree-safe path resolution |
| `context.zig` | Attachment budgets and disclosure |
| `acp.zig` | ACP v1 client semantics over the shared RPC connection |
| `mcp.zig` | MCP stdio client and read-only hint handling |
| `skills.zig` | Markdown skills parse/search/prompt injection |
| `auth.zig` | User-owned provider credentials and redaction |
| `rpc.zig` | Shared newline-delimited JSON-RPC 2.0 stdio connection |
| `cancel.zig` | Cooperative cancellation token |
| `host.zig` | Host callback boundary (no GTK) |
| `controller.zig` | GTK agent dock panel driving the engine (UI side) |

**Threading.** Each `send` runs on a worker thread under a single engine mutex;
the UI drains queued events through `pollEvent` and never blocks on provider or
subprocess work. `rpc.zig` spawns one child process with piped stdin/stdout: a
reader thread parses bounded lines and correlates responses to pending
requests, while a dispatcher thread delivers incoming requests/notifications
(which may block, e.g. for permission prompts) without stalling response
processing.

## Engine API

The engine is the public backend API for the UI controller:

| Method | Purpose |
| --- | --- |
| `newThread(opts)` | Create a thread (title, provider, optional worktree); sets up skills/MCP |
| `send(thread_id, text, attachments)` | Queue a user turn; runs on a worker thread |
| `cancel(thread_id)` | Cooperative cancellation of the active run |
| `respondPermission(thread_id, request_id, decision)` | Answer an `ask` permission request |
| `acceptReview(thread_id, review_id)` | Apply a proposal after the stale-revision re-check; snapshot a checkpoint |
| `rejectReview(thread_id, review_id)` | Discard a proposal without side effects |
| `setProvider(thread_id?, selection)` | Select `fake`/`openai`/`acp` for a thread or the default |
| `probe(name)` | Probe a provider/backend by name |
| `pollEvent()` | Drain the next queued UI event (non-blocking) |
| `waitIdle(thread_id)` | Block until the thread is idle (test synchronization) |
| `threadState(thread_id)` | Current thread state snapshot |
| `searchSkills(thread_id, query)` | Keyword-ranked skill matches |
| `revertCheckpoint(checkpoint_id)` | Restore checkpointed original contents |

## Providers and authentication

- **`fake`** — deterministic, scripted, offline. The CI/default provider; no
  API key, network or paid service is required. The default script streams text
  only (no tool calls); tool flows are exercised by the permission/review
  fixtures and the protocol suite.
- **`openai`** — opt-in OpenAI-compatible HTTP provider using `std.http.Client`
  in the calling worker, with SSE streaming. The endpoint (`base_url`) and API
  key come **only from user config or a named environment variable**; **no proxy
  is ever substituted and no secret is logged**. Provider requests transmit the
  selected code/context and can incur cost; enabling it is an explicit user
  action.
- **`acp`** — external ACP agent sessions (below), selected with an argv/cwd
  configuration.

**Authentication.** `auth.zig` reads user-owned
`$XDG_CONFIG_HOME/coral/auth.json` (or `~/.config/coral/auth.json`):

```json
{ "providers": { "openai": { "api_key": "...",
                             "api_key_env": "OPENAI_API_KEY",
                             "base_url": "https://api.openai.com/v1" } } }
```

Keys resolve from config first, then from the configured environment variable
(never a hardcoded default secret). `redact` scrubs secrets from any rendered
text before it reaches logs or the host sink. `base_url` is always user-supplied;
the backend never substitutes a proxy. No live provider/network tests were run
for this increment.

## ACP v1 external agents

`acp.zig` wraps the shared `rpc.Connection` with Agent Client Protocol v1
semantics over stdio:

- **Initialize** with `protocolVersion: 1` and capability negotiation; omitted
  agent capabilities default to `false`. A mismatched protocol version is
  refused (`error.UnsupportedProtocol`).
- **Sessions:** `session/new`, `session/prompt` with streamed `session/update`
  notifications, and `session/cancel`.
- **Agent→client requests:** permission requests answered allow/deny/cancel;
  filesystem reads/writes routed through the host (**writes go through the
  review flow**, never direct); terminal callbacks driven through the host
  PTY boundary.
- **Safety:** disconnect, malformed frames, fragmented lines and late duplicate
  responses are handled without crashing or applying side effects; cooperative
  cancellation covers RPC waits.

The provider picker's **empty ACP argv clean-fails** (`state=failed`, no spawn)
instead of launching anything; real adapter argv configuration is future work.
**ACP is not a sandbox:** an external process can bypass client-side tool
callbacks through its own filesystem/network access and runs with user
permissions. The UI must never overstate enforcement.

## MCP tools

`mcp.zig` is a Model Context Protocol stdio client: `initialize` →
`notifications/initialized` → `tools/list` → `tools/call`. Tools advertise a
read-only hint; the engine **allows read-only tools and requires approval for
any non-read-only (writable) tool** before calling it. The fake MCP fixture
never touches the host filesystem. MCP tools are registered and permissioned
separately from the built-in tools.

## Skills

`skills.zig` loads markdown skill files from workspace `.coral/skills`
directories. Optional YAML-ish frontmatter delimited by `---` lines carries
`name:` and `description:`; without frontmatter the filename stem becomes the
name. Skills are searched by keyword (case-insensitive substring scoring) and
the selected ones are rendered into a system-prompt section **with disclosure of
their source paths**. Repository text cannot grant permissions or override
policy; skills are prompt context, not executable configuration.

## Threads, persistence and worktree binding

- **State machine.** `thread.zig` permits only legal transitions
  (idle → streaming → awaiting_* → idle, cancellation, failure, closure), so the
  UI and backend agree on lifecycle.
- **Persistence.** `store.zig` writes each thread as one JSON file under
  `$XDG_STATE_HOME/coral/agents` (or `~/.local/state/coral/agents`), written to a
  temporary sibling and renamed into place so a crash never leaves a partial
  thread file. Restoration skips unreadable/corrupt files rather than failing
  the whole load; per-file reads are capped at 4 MiB.
- **Worktree binding.** A thread binds to an optional worktree (root + branch).
  `tools.zig` resolves tool paths against the bound worktree root, so concurrent
  agents bound to different worktrees stay isolated. Bindings are stable;
  changing the visible workspace does not retarget an active tool.

## Review, checkpoints and tool policy

- **Proposals.** `review.zig` records, per file, the base revision (SHA-256 of
  the content at proposal time, or a sentinel for an absent file) and the
  proposed content.
- **Stale refusal.** Accepting re-reads every file and **refuses the whole
  proposal if any base revision changed** (`error.StaleRevision`), performing
  **no writes** in that case.
- **Checkpoints.** On success a checkpoint snapshots the original contents so
  the edit can be reverted through `revertCheckpoint`. Rejection discards the
  proposal without side effects.
- **Policy.** `policy.zig` decides allow/deny/ask per tool. Defaults: read-only
  tools (`read_file`, `list_dir`, `search`) and `propose_edit` allow (edits still
  go through review), `run_terminal` asks, unknown tools fall back to the
  default `ask`. **A `deny` decision never invokes a host callback**; the engine
  returns a denial result instead. `ask` defers to an interactive permission
  request answered by `respondPermission`.
- **Staged-proposal default.** Proposed edits are staged for review before
  applying; no live-edit mode is offered. This is the plan's deliberate safety
  difference from agents that write first and review later.

## Context attachments and cancellation

`context.zig` bounds attachments (file / selection / diagnostics / git_diff /
folder) to a per-kind byte budget (file attachments default to 64 KiB) and an
overall total budget, truncating without splitting UTF-8 code points. Every
rendered prompt carries a **disclosure header** listing what was attached and
whether it was truncated, so the model and the user see exactly what context was
provided. There is no invisible whole-repository upload.

`cancel.zig` provides a cooperative cancellation token shared by provider
streams, tool runs and RPC waits; `cancel` stops the active run without
replaying completed side effects, and partial edits remain reviewable.

## Agent dock — fifth panel, persisted layout

`src/agent/controller.zig` owns the GTK agent panel and drives the GTK-free
engine: **thread list, streaming transcript, context attachment chips, provider
picker, permission cards, review proposals with accept/reject, skills search,
cancel and status**. The panel is the **fifth dock panel** beside
Explorer/Search/Source Control/Terminal: movable left/right/bottom, resizable,
hideable, with activity rail/tabs. `layout.State` persists agent side/visibility
(**default hidden right**; old sessions decode to it), covered by the layout
unit tests and native docks.

The instrumented binary exposes a **`CORAL_AGENT` JSON probe** describing the
live panel and backend state (threads, active thread, message counts, busy/idle,
provider), which the native harness uses to drive and assert the fixture bridge.
Production builds omit the test controls.

## Commands

All M6/M7 commands are palette/menu-driven; **none has a default keybinding**.

| Action | Palette label |
| --- | --- |
| `toggle-agent` | Toggle Agent dock |
| `focus-agent` | Focus Agent |
| `agent-new-thread` | Agent: New thread |
| `agent-send` | Agent: Send message |
| `agent-cancel` | Agent: Cancel run |
| `agent-allow` | Agent: Allow permission |
| `agent-deny` | Agent: Deny permission |
| `agent-accept-review` | Agent: Accept review |
| `agent-reject-review` | Agent: Reject review |

## Fixtures

Protocol and native acceptance use disposable, offline fixtures only:

- **`tests/fixtures/acp_adapter_echo.py`** — fake ACP adapter exercising
  default/omit-capabilities/permission/fs/terminal/disconnect/malformed/fragment/
  late/slow modes.
- **`tests/fixtures/acp_adapter_edit.py`** — fake ACP edit adapter for
  review-flow parity.
- **`tests/fixtures/mcp_server_fake.py`** — fake MCP server; never touches the
  host filesystem.
- **Native fixture workspace** — disposable roots with `notes.txt` and real
  `.coral/skills` markdown (`zig-style`, `git-commit`, `python-tips`), private
  Wayland/D-Bus/HOME/XDG sessions, and panel snapshots (`agent-panel-focused`,
  `fake-thread-streamed`, `permission-review-fixtures-inert`,
  `cancel-idle-and-resend`, `provider-picker-and-clean-acp-failure`,
  `skills-search`, `thread-selection`, `thread-store-survives-restart`,
  `thread-and-transcript-bounds`).

`agent-protocol-unit` requires Linux, `python3` and `/bin/sh`; the adapters are
spawned as disposable subprocesses. **Real external ACP/MCP adapters are not
installed, and no real-adapter feature matrix is claimed.** CI requires no API
key or paid service.

## Limits and intentional differences

- **ACP picker empty argv clean-fails** (`state=failed`, no spawn). Real adapter
  argv configuration is future work; no real adapters are installed or claimed.
- **The UI does not rebuild restored threads.** Engine-level restoration is
  covered (store tests and the `thread-persistence` native case); rebuilding the
  transcript UI from restored threads remains future work.
- **Host root bind timing** remains a recorded edge.
- **The fake default script makes no tool calls**; tool/permission/review flows
  are exercised by the dedicated fixtures and the protocol suite, not the
  default streaming script.
- **No live provider/network tests.** The OpenAI-compatible provider is
  implemented but was not exercised against a live endpoint; no API key, paid
  service or network provider test was used.
- **Staged-proposal review only**; no live-edit mode, and the broader Zed-parity
  targets (Ask/Plan/Edit profiles, inline assistant, edit prediction, thread
  rename/archive/export UI, real pinned-adapter feature matrix) remain roadmap
  work, not delivered capabilities.
- **Always-trusted workspace.** By user request there is no workspace consent
  prompt; tool permissions and review remain. ACP external processes run with
  user permissions and can bypass client-side callbacks. These are
  application-level protections, **not an OS sandbox**.
- The visual gate is existing-workbench regression coverage, not agent-panel
  visual parity, and is pending the parent aggregate.

## Targeted validation

**Targeted validation passed; the full aggregate was not rerun.**

| Target | Result | Evidence |
| --- | --- | --- |
| `agent-core-unit` | **54/54** | [slice log](../../../.cache/coral-m6-slice.log) |
| `agent-protocol-unit` | **62/62** | [slice log](../../../.cache/coral-m6-slice.log) |
| `agent` (native) | **9/9** | [slice log](../../../.cache/coral-m6-slice.log), [results](../../../.cache/coral-agent/results.json) |
| `docks` (native) | **27/27** | [slice log](../../../.cache/coral-m6-slice.log) |
| `session-unit` | **29/29** | [slice log](../../../.cache/coral-m6-slice.log) |
| `widgets` | **218 pass** | separate targeted gate |
| `layout` | **5/5** | separate targeted gate |
| build | **pass (46/46 build steps)** | [build log](../../../.cache/coral-m6-production.log) |

`test-m6-slice` composes the agent core/protocol/native gates with docks and
session-unit (**47/47 steps, 145/145 tests**), not M1–M4 regressions. The
GTK-free unit suites need no display or ghostty prefix; the native `agent` step
and `test-m6-slice` build the instrumented binary and need `-Dghostty-prefix`
plus the private harness. The build log records a fresh safe-optimized
production executable compile.

Native agent cases: `panel-probe-show-hide`, `fake-thread-send-stream`,
`permission-review-inert`, `cancel-and-resend`, `provider-picker`,
`skills-search`, `select-thread`, `thread-persistence`, `bounds`. The
permission/review fixtures are asserted **inert without a pending request**;
the provider-picker case covers the clean ACP empty-argv failure; the
persistence case survives a restart through the XDG thread store; the bounds
case covers thread/transcript limits and command timeout/failure states.

**Pending parent:** the full aggregate was not rerun; hooks-disabled production
and visual gates await the parent aggregate. M1–M5 gates remain historical.
Counts overlap across harnesses; they are not a unique-test total. Protocol
parity is exercised against the two fake ACP adapters and the fake MCP server
only; real external adapters are not installed and no real-adapter feature
matrix is claimed.

## Next

**M8 is next** (complete local IDE): DAP/test runner, extension packages,
advanced editing including interactive snippets, and keymap/accessibility
polish. Remaining agent work stays explicit: real adapter argv configuration and
the pinned-adapter feature matrix, UI rebuild of restored threads, live
provider/network validation, and the broader Zed-parity targets above. See the
[implementation plan](WORKBENCH_IMPLEMENTATION_PLAN.md) and
[current status](WORKBENCH_STATUS.md).
