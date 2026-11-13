# Workbench OpenCode primary agent plan — varro-identical connection

Status: **PROPOSED — no code changed.** Owner sign-off required on decisions
D1–D7 before implementation. Implementation starts only on explicit request.

Goal (owner instruction): make **OpenCode the primary Coral agent**, connecting
**in exactly the same manner as varro** (`koltyakov/varro`, the OpenCode
workbench for VS Code). This plan operationalizes "exactly the same manner"
as a verified, behavior-identical reimplementation of varro's connection
lifecycle and workbench contract in Zig, on Coral's existing host services.

---

## 0. Verified baseline (evidence, not assumption)

| Fact | Source (verified) |
| --- | --- |
| varro = `koltyakov/varro` v0.34.10, **MIT**, TypeScript VS Code extension | repo `package.json`, README |
| Connection = **OpenCode HTTP server** (`opencode serve`), REST + SSE — **NOT ACP** | `docs/architecture.md`, README |
| varro uses the official SDKs: `@opencode/client ^2.2.7` (v2) and `@opencode-ai/sdk ^1.19.5` (v1); auto-detects the connected API | `package.json` dependencies, README |
| Ownership split: **OpenCode owns** agents, providers, models, commands, skills, MCP servers, compaction, tool execution, configuration, session state; **varro owns** server lifecycle, GUI, workspace scoping, local `/varro/*` services; sessions can continue in the OpenCode TUI | README, architecture.md |
| OpenCode = `anomalyco/opencode`, **MIT** (Copyright (c) 2025 opencode) | LICENSE file |
| CLI families: v2 `@opencode/cli` (varro-tested **2.2.7**, floor 2.0.5); v1 `opencode-ai` (tested **1.19.5**, floor 1.16.0); discovery order `opencode2` then `opencode`, or configured command | README, `varro.server.command` |
| `opencode serve [--port 4096] [--hostname 127.0.0.1] [--cors …]`; auth = `OPENCODE_SERVER_PASSWORD` HTTP basic auth (username `opencode` or `OPENCODE_SERVER_USERNAME`); OpenAPI 3.1 spec at `/doc`; `/global/health` → `{healthy, version}`; `/global/event` SSE; `/tui/*` endpoints exist for IDE plugins | opencode.ai server docs (v1 page) |
| **Docs-version nuance:** the fetched endpoint inventory is from the **v1** docs page. The authoritative v2 contract must be pinned from the running pinned server's `/doc` spec (P1). varro-documented v2 differences: no OpenCode LSP service; session annotations stored locally by the client; decision generation ≥ 2.2.0; stateless generation for follow-ups; session sharing discontinued | opencode.ai docs banner; varro README |
| Coral today: M6/M7 native engine + ACP v1 client + Agent dock (picker `fake/openai/acp`); HTTP/SSE client code already exists (`provider.zig` `HttpTransport`, `SseHandler`) | coral source |
| Environment precedents: Aqueous development already uses opencode (`opencode.json`, `skills/system` in opencode skill format); Pearl bundles external runtimes (`llama-server` under `libexec` with `runtime.json` pin); Pearl has a notification service (notifications/DND) | Aqueous/pearl trees |

---

## 1. Fidelity contract — "exactly the same manner as varro"

### 1.1 Connection lifecycle (the core requirement)

All behaviors below are verified from varro's `architecture.md`, README, and
`package.json` configuration. Coral must reproduce them:

1. **Lazy, workspace-scoped startup.** Construct the server manager at
   activation; start only when the UI first needs it (`ensureServerStarted`).
2. **CLI discovery.** Configured executable path, else `opencode2` then
   `opencode` on PATH.
3. **Health check before auto-start; reuse verified servers** across reloads
   and updates; remember an auto-selected local port; **explicit ports never
   silently fall back**; on managed-start port conflict, retry nearby ports.
4. **Credentials for new managed servers** (`OPENCODE_SERVER_PASSWORD` basic
   auth).
5. **Ownership guard.** Unknown server ownership or a different OS user
   requires confirmation before loading sessions (prevents accidental
   attachment; not access control for an unauthenticated server).
6. **Attach-only mode** (`autoStart=false`): manually managed / Docker /
   tunneled servers; local CLI and file-based config actions unavailable.
7. **Event stream.** Connect SSE at `/global/event`; route detailed events
   only to the endpoint owning their execution directory; project safe
   session lifecycle/status summaries across open roots. SSE drop →
   exponential backoff retry; SSE down while REST healthy → **degraded
   banner** (live updates and request availability treated separately);
   child process exit after startup → limited restart sequence.
8. **Restart safety.** Restart waits for active work (restart-blocked state);
   only varro-managed servers are restarted; manual servers are the user's.
9. **Version maintenance.** Compare installed CLI vs server versions; suggest
   `opencode upgrade`; restart an idle managed server onto the newer version;
   auto-update within the installed CLI family; **never migrate v1→v2**.
10. **Directory semantics.** Workspace-sensitive requests carry an
    authoritative directory. On Linux, managed servers receive the
    **physical (symlink-resolved) workspace directory** (matching a
    terminal-launched TUI); restore the editor's symlinked spelling in
    single-line path values from responses/events. Attach-only servers
    receive exact paths.
11. **Session catalog authorization.** Exact-directory / project /
    cross-project scopes; filter hidden and recycled sessions before global
    sorting/pagination; authorize direct session operations from the
    validated catalog; include nested Git projects without exposing sibling
    directories. Permissions, questions, messages, tools, diffs remain
    directory-owned.
12. **Dual-version support.** Detect the connected API (v1/v2) and use the
    same workbench for either; v2 recommended (decision D2).

### 1.2 Workbench behavior parity

- **Sessions:** parallel sessions; queue follow-ups, steer a running session,
  stop-and-replace; queued prompts persisted host-side and auto-dispatched
  when the owning session is connected and idle (including background
  sessions); child sessions linked to parents, inheriting the nearest
  permission mode, with manual requests surfaced in the parent chat;
  Recent / Archive / Recycle Bin; pins, hidden sessions, rename-if-untitled;
  windowed message loads (newest 200, anchor-preserving 200-message prepend);
  interrupted-session recovery after reload; TUI handoff; session cleanup
  that archives usage before deleting and preserves active/parent sessions.
- **Prompt construction (exact part order):** user text → working-directory
  marker → active file/selection marker (per-session toggle) → terminal
  selection block → attached diagnostics → explicit files/folders, pasted
  images, native PDFs in attachment order. Images require vision support;
  PDFs require advertised input support (v2 also checks the native model
  catalog), 20 MiB total, **no silent substitution or page conversion**.
- **Permissions:** answers `Reject` / `Once` / `Always`; per-session modes
  `Default` (follow OpenCode rules) / `Auto` (local rules + optional model
  judge; undecided → manual) / `Full access`; **default Auto**; child
  inheritance. Auto judge may use a server-hosted decision model
  (OpenCode ≥ 2.2.0) with probability gates and fallback.
- **Attention model:** running / attention-needed / failed / completed /
  plan-ready, derived from `permission.asked`, `question.asked`,
  `session.idle` plus pending snapshots; desktop notifications **off by
  default** (Linux: `notify-send`; sounds `paplay`/`aplay`/
  `canberra-gtk-play`); status indicator.
- **Context:** active file+selection by default (per-session chip toggle);
  `@` files/agents, `&` recent root sessions; drag-and-drop (path-based and
  content-only → temp drop directory); pasted images; diagnostics; terminal
  selection capture with clipboard restore; `ctrl+shift+k` add-to-context.
- **Models/providers:** capability-aware picker; local pin/hide/rename (UI
  preferences only — never modify OpenCode model IDs); model routing config;
  auth via OpenCode `/provider`, `/provider/auth`, provider OAuth,
  `/auth/:id`; **the host never receives API keys or authorization codes as
  dedicated protocol messages**; auth/config file observation → provider
  invalidation and revalidation without unnecessary restarts; authentication
  failures projected into reconnect state.
- **MCP:** servers come from OpenCode configuration; per-session selection
  (not tool isolation); Global/This-project auto-connect settings written
  into OpenCode config (project overrides global; "Use global" removes the
  project entry); on-demand servers connect when selected; shared
  connections stay up while running work needs them.
- **Usage:** context-window fill; token/cost breakdown; stats (today / 7d /
  30d / all-time); CSV export (UTC, separate input/output/reasoning/cache
  columns); provider quota windows and reset times; limit errors → stop
  retries or switch providers.
- **Commit messages:** draft from staged changes (unstaged fallback), fill
  the commit input for review; **never stage or commit**; ask before
  replacing an existing draft; per-repository style rules; model override.
- **Plans:** plan-agent sessions → plan-ready state; normalize the plan
  response, save into the local OpenCode plans directory, open in the editor.
- **Web search:** on client-launched v2 servers, default automatic provider
  selection (`"random"`) when no preference exists; configured providers and
  saved choices (including disabled) preserved.
- **Slash commands:** reviews, compaction, exports, stats, skills,
  diagnostics, forks (Ralph excluded initially — see 1.3).

### 1.3 Out of scope (declared deviations)

- **VS Code-specific surfaces** → GTK/Coral equivalents: webview/CSP/bridge,
  VS Code commands/menus/keybindings map onto Coral's command registry and
  dock; the connection contract is identical, the UI substrate is not.
- **Ralph loops** (varro's host-owned plan orchestration) — a product
  feature, not the connection; optional later increment.
- Mobile PWA, macOS tray/notification helpers, dictation (Handy/Hex),
  thumbnail wasm, VS Code fork compatibility.
- Optional v2 extras: follow-ups, inline prompt completion, promptTrace
  proxy attribution — deferred, off by default (D6).
- TypeSafe Jev judge — sends permission details to a third party; excluded
  by default (D4).
- **No code copying by default.** Original Zig client against the pinned
  OpenCode contract; varro is MIT, so borrowing is legally possible with
  notices if explicitly chosen later.

---

## 2. Coral architecture

- New GTK-free backend `src/agent/opencode/` (Zig):
  `process.zig` (CLI discovery, spawn, port, credentials, ownership, restart,
  update), `transport.zig` (REST + SSE, backoff, degraded state),
  `lifecycle.zig` (state machine), `catalog.zig` (directory-scoped session
  catalog + authorization), `events.zig` (normalization/routing),
  `auth.zig` (provider endpoints + file watch), `permissions.zig` (modes,
  responses, judge bridge), `prompt.zig` (part construction),
  `usage.zig`, `mcp.zig` (config read/write), `plans.zig`, `commit.zig`.
- **Dock integration:** opencode becomes the **primary/default** provider;
  picker retains `fake` (CI), `openai`, `acp`. Coral thread ↔ OpenCode
  session mapping; Coral's store keeps **UI metadata only** (pins, hidden,
  recycle bin, queue, annotations); **OpenCode owns conversation truth** —
  no dual source of truth.
- **Host boundary:** Coral editor context (active file/selection,
  diagnostics, terminal selection) → prompt parts; diffs and tool output →
  read-only Coral editor documents; notifications → Pearl's existing
  notification service; commit drafts → Coral git dock (M4) commit input;
  worktrees → per-worktree directory scoping (opencode cwd).
- **Threading:** existing controller contract — workers for HTTP/SSE, event
  queue drained by bounded `g_timeout` pump, all GTK mutation on the main
  loop, cooperative cancellation tokens.
- **Runtime:** the opencode CLI is an external process discovered on
  PATH/config (exactly like varro). No Node runtime inside Coral. Packaging
  per D5: Shelly dependency, or bundled under `libexec` with a `runtime.json`
  pin (llama-server precedent).

---

## 3. Decision register (owner sign-off required)

| ID | Decision | Default |
| --- | --- | --- |
| D1 | opencode replaces `fake` as dock default; native engine frozen (kept for CI/reference), `openai`/`acp` retained | Adopt |
| D2 | Version policy: mirror varro (v2 primary + v1 auto-detection) vs v2-only pin (declared deviation, less work) | Mirror varro |
| D3 | Safety model: opencode applies edits under its own permission system; Coral's inert-proposal/review-first (M0 D2) and checkpoints (D3) do not apply to opencode sessions. Disclose: the opencode process has user-level access; **not an OS sandbox**. varro refuses untrusted workspaces for this reason; Coral is always-trusted by prior explicit decision — interaction flagged | Adopt with disclosure |
| D4 | Auto permission judge: default Auto like varro; local rules first; model judge opt-in (permission details go to the judge model — disclose); TypeSafe Jev excluded | Adopt |
| D5 | Runtime packaging: PATH dependency vs bundled `libexec` pin | Decide |
| D6 | Optional extras (follow-ups, prompt completion, promptTrace, Ralph): deferred increments, off by default | Defer |
| D7 | License/governance: opencode MIT + varro MIT → no GPL obligation; process integration = aggregation; ship CLI notices if bundled. Pearl's own grant is still pending (`LicenseRef-Pearl-Unlicensed`) — a release gate, not a legal blocker for this integration | Record notices |

---

## 4. Pins and contract sources

- **OpenCode v2:** 2.2.7 (varro-tested), floor 2.0.5, CLI `@opencode/cli`.
  **v1:** 1.19.5, floor 1.16.0, CLI `opencode-ai`.
- **Authoritative contract:** OpenAPI 3.1 specs fetched from `/doc` of the
  running pinned v2 and v1 servers; hash and record in
  `OPENCODE_PORT_MANIFEST.md` (M0 culture). The v1 endpoint inventory in
  Appendix A is verified from the v1 docs page; v2 differences are pinned
  from the spec, not from docs.
- **SDK references:** `@opencode/client` 2.2.7, `@opencode-ai/sdk` 1.19.5
  (behavioral reference only; no TS code in Coral).
- **varro behavior reference:** v0.34.10 — resolve commit, hash README,
  architecture.md, usage.md, permissions.md into the manifest.
- **Compatibility floor report:** `artifacts/opencode-compatibility.json`,
  mirroring varro's `scripts/opencode-compatibility/verified.json` culture.

---

## 5. Phases and exit gates

| Phase | Scope | Exit gate |
| --- | --- | --- |
| **P0 — governance** | D1–D7 sign-offs; pins + hashes; notices | Decisions minuted; manifest skeleton |
| **P1 — transport core** | Spec pinning (v1+v2 `/doc`); process lifecycle (discovery, health, port memory/reuse, credentials, ownership, attach-only, restart safety); REST+SSE client with backoff/degraded states | `opencode-transport-unit` vs fake HTTP+SSE fixture server; attach-only against a real manually started server |
| **P2 — sessions + chat** | Catalog/scopes/authorization; session CRUD; prompt parts; streaming transcript; windowed loads; queue/steer/abort; child sessions; interrupted recovery | End-to-end with pinned real CLI + local fake OpenAI-compatible provider (deterministic CI, no paid keys) |
| **P3 — permissions + attention** | Modes, Reject/Once/Always, judge bridge (local rules first), Pearl notifications, status | Permission parity fixtures; denied requests have no side effect |
| **P4 — context + editor** | Context chips, `@`/`&` mentions, attachment gates (vision/PDF), diff/tool-output documents, plans save/open | W-story fixtures |
| **P5 — models/providers/MCP/usage** | Picker, auth flows + file watch, MCP toggles/config writes, stats/CSV/quotas | Opt-in live auth test; MCP fixtures |
| **P6 — workbench extras** | Commit drafting into git dock, TUI handoff, recycle bin/pins/hidden, session cleanup | Workflow fixtures |
| **P7 — hardening + parity audit** | Version maintenance/update loop, symlink path handling, degraded modes, restart safety, compatibility floor report, RELEASE.md gates | Parity audit vs pinned varro behavior + physical/visual/accessibility signoffs |

**Thinnest end-to-end slice first:** P1 + minimal P2 (one session, prompt,
stream, abort) → a working primary agent early; breadth afterwards.

---

## 6. Validation strategy

- **Fake opencode server** (HTTP+SSE fixture) for CI: fragmented/malformed/
  oversized frames, disconnects, duplicate/out-of-order events, late
  responses, port conflicts, ownership mismatch, SSE-drop-with-REST-alive,
  catalog sibling-isolation negatives.
- CI requires no API key or paid service: opencode pointed at a local fake
  OpenAI-compatible endpoint; live gates opt-in with user credentials.
- `zig build test` steps `opencode-*-unit` alongside existing suites;
  targeted validation per phase, parent aggregate before release.
- Never run destructive tests against the developer checkout (M0 rule).

---

## 7. Risks

- **v1/v2 API churn** — mitigated by spec pins + compatibility floor report
  (varro's own culture).
- **Catalog authorization complexity** — varro's trickiest area (directory
  ownership, cross-project projection, nested repos); budget accordingly.
- **Auto-judge privacy** — permission details sent to the judge model;
  disclose, local rules first, third-party judges excluded.
- **User-level process access** — opencode is not sandboxed; interacts with
  Coral's always-trusted decision (D3); label honestly in UI.
- **CLI runtime dependency** — discovery, updates, packaging (D5).
- **Feature breadth** — varro is a mature product (0.34.x); connection
  parity first, extras gated; full surface is a program, not a patch.
- **Dual truth** — OpenCode owns sessions; Coral stores UI metadata only.

---

## 8. Immediate next actions (no code yet)

1. Owner: sign D1–D7.
2. Generate `OPENCODE_PORT_MANIFEST.md` (CLI versions, `/doc` spec hashes,
   varro commit + doc hashes).
3. Spikes: SSE client reuse from `provider.zig` (`HttpTransport`/
   `SseHandler`); `opencode serve` credentials flow; CLI discovery in the
   Shelly environment.
4. Begin P1 **only on explicit request**.

---

## Appendix A — verified v1 server API inventory (opencode.ai v1 docs page)

Pin the authoritative v2 spec from `/doc`; this inventory is the verified v1
baseline and the shape of the contract.

- **Global:** `GET /global/health` `{healthy, version}`; `GET /global/event`
  (SSE).
- **Project/Path/VCS:** `GET /project`, `/project/current`, `/path`, `/vcs`;
  `POST /instance/dispose`.
- **Config:** `GET/PATCH /config`; `GET /config/providers`.
- **Provider/Auth:** `GET /provider`, `GET /provider/auth`,
  `POST /provider/{id}/oauth/authorize`, `POST /provider/{id}/oauth/callback`,
  `PUT /auth/:id`.
- **Sessions:** `GET/POST /session`; `GET /session/status`;
  `GET/PATCH/DELETE /session/:id`; `GET /session/:id/children`, `/todo`;
  `POST /session/:id/init`, `/fork`, `/abort`, `/summarize`, `/revert`,
  `/unrevert`; `GET /session/:id/diff`;
  `POST /session/:id/permissions/:permissionID` `{response, remember?}`.
- **Messages:** `GET/POST /session/:id/message` (send waits; parts-based);
  `GET /session/:id/message/:messageID`; `POST /session/:id/prompt_async`
  (204); `POST /session/:id/command`; `POST /session/:id/shell`.
- **Commands/Files:** `GET /command`; `GET /find`, `/find/file`,
  `/find/symbol`, `/file`, `/file/content`, `/file/status`.
- **Tools (experimental):** `GET /experimental/tool/ids`,
  `/experimental/tool`.
- **LSP/Formatter/MCP:** `GET /lsp`, `/formatter`, `/mcp`; `POST /mcp`.
- **Agents:** `GET /agent`.
- **TUI (IDE-plugin surface):** `POST /tui/append-prompt`, `/submit-prompt`,
  `/clear-prompt`, `/execute-command`, `/open-*`, `/show-toast`;
  `GET /tui/control/next`; `POST /tui/control/response`.
- **Logging/Docs:** `POST /log`; `GET /doc` (OpenAPI 3.1).

Approval state: **not recorded.** This plan is a planning output; product
approval and executable parity evidence are separate gates.
