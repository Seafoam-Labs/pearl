# Workbench Zed agent port plan — GPLv3, pinned v1.27.0

Status: **PROPOSED — no code copied or changed.** Owner sign-off is required at
gate G0 (license grant) and on the superseded-decision register S1–S7 before any
translation begins. This document is the requested plan; implementation starts
only on explicit request after the gates pass.

Goal (owner instruction): copy Zed's workflow and agent **exactly** into Zig,
1:1, now that Pearl is to be GPLv3. This plan operationalizes "exactly" as a
faithful, notice-preserving translation of Zed's **agent subsystem** onto
Coral's existing host services, with every unavoidable deviation declared.

---

## 0. Verified baseline (evidence, not assumption)

| Fact | Evidence |
| --- | --- |
| Pearl is **currently unlicensed**, not GPLv3 | No `LICENSE` at repo root; `packaging/arch/PKGBUILD`, `arch-git`, `Devario/*`, lang packs all declare `license=('LicenseRef-Pearl-Unlicensed')`; `docs/RELEASE.md`: owner license selection pending, blocks public release |
| Zed agent crate license | `crates/agent/Cargo.toml`: `license = "GPL-3.0-or-later"`; repo root carries `LICENSE-GPL` + `LICENSE-APACHE` |
| Pin | Zed **v1.27.0**, commit `c84af5b99cbc366d675064e52b23664a015b6e35` (M0 frozen reference) |
| Architecture exists at the pin | `crates/agent/src` listing verified **at `c84af5b`**: `native_agent_server.rs`, `thread.rs`, `thread_store.rs`, `db.rs`, `tool_permissions.rs`, `tools/`, `templates/`, `sandboxing.rs`, `pattern_extraction.rs`, `outline.rs`, `legacy_thread.rs` |
| Pinned release removed checkpoints | M0 finding: v1.27.0 removed agent checkpoints / Restore Checkpoint (performance) |
| ACP wire target | schema release `schema-v1.29.1`, wire `protocolVersion: 1` (M0 pin; never send `1.29.1` as the wire version) |
| Coral today | M6/M7 native engine (`engine.zig`, `provider.zig`, `tools.zig` 5 tools, `policy/review/store/thread/context/skills/auth/cancel/host/rpc/acp/mcp`), GTK dock `controller.zig` (picker `fake/openai/acp`), JSON persistence, review-first edits, always-trusted workspace |

License math: a Rust→Zig translation is a **derivative work**. It is permitted
only once Pearl carries a GPL-compatible grant. `GPL-3.0-or-later` (Zed agent)
and `Apache-2.0` (some Zed crates) are both compatible with a GPLv3 Pearl.
Recommended grant: **GPL-3.0-or-later** (matches upstream, maximizes
compatibility).

Source URL convention for every ported file (genuine links only, no proxy
substitution):

```
https://raw.githubusercontent.com/zed-industries/zed/c84af5b99cbc366d675064e52b23664a015b6e35/<path>
```

---

## 1. Fidelity contract — what "1:1 / exactly" means

**In scope (faithful translation, behavior-identical):**

- Native agent loop and thread state machine (`agent/thread.rs`, `agent.rs`).
- The unified thread/content model shared by native and external agents
  (`acp_thread/*`), including the native agent exposed as an **in-process ACP
  server** (`native_agent_server.rs`).
- Tool schemas and semantics — all ~25 tools in `agent/src/tools/`, including
  `edit_file` + `edit_session` + `streaming_diff`, terminal, diagnostics,
  LSP-backed tools, fetch/web_search, path CRUD, ask_user, skill, subagents.
- Prompts and templates **byte-identical** (`agent/src/templates/`,
  Handlebars; `prompt_store`, `agent_skills`).
- Per-tool permissions and profiles/modes (`tool_permissions.rs`,
  `agent_settings`).
- Persistence schema (SQLite via `db.rs`/sqlez), thread metadata/archive.
- Provider abstraction and wire shapes (`language_model`, `language_models`).
- External ACP agents (`agent_servers`: registry, custom agents, auth methods,
  capability-gated UI).
- Panel workflows and keymaps (`agent_ui/*`): history/archive, mentions,
  model/profile/mode selectors, tool cards, agent diff keep/reject, inline
  assistant (editor + terminal), follow, `ctrl-n` NewThread, `ctrl-shift-r`
  OpenAgentDiff.
- Compaction, cancellation ordering, malformed/disconnect safety.

**Out of scope (structural deviations, declared up front):**

- **GPUI internals** → GTK4 via Coral's established controller pattern
  (worker threads + event queue + bounded `g_timeout` pump). Flows match;
  framework internals cannot.
- **Zed's editor/project/buffer/fs/git/task/lsp crates** → Coral's existing
  equivalents serve as the host boundary. Porting Zed's whole editor would
  duplicate Coral and is a separate, much larger program; if the owner wants
  that too, it must be commissioned explicitly.
- **Zed cloud / hosted subscription** (`client`, `cloud_*`) — proprietary
  service; client code excluded (M0 D4 already forbids subscription reuse).
- **Telemetry** — stubbed/disabled; no Zed endpoints ever contacted.
- **Collab / remote / notebooks** — excluded (M0 D4).

A literal line-for-line port of all of Zed is not feasible across
Rust/GPUI → Zig/GTK. This plan delivers the agent stack 1:1 in behavior,
structure, prompts, schemas and workflows, on Coral's host. Every deviation
lives in the register below or the manifest — nothing silent.

---

## 2. Gate G0 — license and governance (BLOCKING, before any copy)

1. **Record the grant.** Add `LICENSE` (GPL-3.0-or-later) at the Pearl root and
   Coral; update every `PKGBUILD`/`.SRCINFO` `license` field, `docs/RELEASE.md`,
   and source-archive notices consistently. Until this is done, copying Zed
   code is unauthorized regardless of intent.
2. **Per-crate SPDX audit.** For each ported Zed crate, record its declared
   license and the SHA-256 of every ported file **at the pin** in
   `ZED_PORT_MANIFEST.md` (M0 hash culture). Exclude any non-compatible asset.
3. **Notices and marking.** Translated files keep upstream copyright headers,
   add `Translated from Zed <path>@c84af5b (GPL-3.0-or-later); modified for
   Zig/Coral`, and ship corresponding source. `ZED_PORT_NOTICES.md` maps each
   Zig module to its upstream origin.
4. **Owner sign-off** on S1–S7 below, recorded in this document.

---

## 3. Superseded-decision register (owner sign-off required)

"Exactly" conflicts with earlier explicit product decisions. Each reversal is
the owner's call; defaults reflect the current instruction.

| ID | Current Coral decision | Zed-exact behavior | Default / risk |
| --- | --- | --- | --- |
| S1 (M0 D2) | Proposal-before-apply: inert proposals, wholesale stale-revision refusal | `edit_file` **applies to buffers** (streaming diff, edit session); review **after** via agent diff keep/reject + undo | Adopt Zed per "exactly". **Safety tradeoff: edits auto-applied.** Sign-off required |
| S2 (M0 D3) | Coral checkpoints + `revertCheckpoint` | Pinned v1.27.0 **removed** agent checkpoints/Restore Checkpoint | Adopt Zed: remove/hide checkpoint UI+API. Keep Coral crash recovery (separate feature). Sign-off |
| S3 (M5) | Always-trusted workspace — consent removed **by explicit user request** | Zed workspace trust prompts | **Security-relevant reversal of a prior explicit decision.** Default: KEEP always-trusted as a declared deviation unless the owner explicitly reverses. Sign-off |
| S4 (M0 D1) | Commit staged-only | Zed git panel convenience | Git workflow is outside agent scope; unchanged unless scope extended |
| S5 | — | Zed telemetry/cloud | Excluded (privacy/proprietary); disclosed in About/UI |
| S6 | User-supplied endpoints/keys, no proxy substitution | Zed cloud subscription | Keep Coral auth policy; subscription not reusable (D4) |
| S7 | JSON thread persistence | Zed SQLite schema | Migration tool (no data loss) vs clean break — decide; default: migrate |

---

## 4. Port inventory (upstream@pin → Zig destination)

Listings verified via the GitHub API at `main` and re-verified for
`crates/agent/src` at the pin; P1 re-hashes every file at `c84af5b` and
resolves any drift **in favor of the pin**.

| Upstream crate | Verified contents (abridged) | Zig destination | Notes |
| --- | --- | --- | --- |
| `language_model` | `registry`, `request`, `language_model`, `api_key`, `fake_provider` | `src/agent/zport/language_model/` | Replaces `provider.zig` abstraction; fake provider kept for CI |
| `language_models` | `provider/` (anthropic, open_ai, google, ollama, openai_compatible, …), `settings`, `extension` | `src/agent/zport/providers/` | Cloud provider excluded; extension host out of scope |
| `acp_thread` | `acp_thread`, `content`, `connection`, `compaction`, `mention`, `diff/`, `terminal`, `subagents`, `submission`, `elicitation`, `auth_methods`, `config_options`, `prompt_capabilities`, `commands`, `notices` | `src/agent/zport/acp_thread/` | Shared native+external thread model — the architectural core |
| `agent` | `thread`, `agent`, `thread_store`, `db`, `tool_permissions`, `tools/` (~25 tools incl. `edit_session/`), `templates/`, `native_agent_server`, `sandboxing`, `pattern_extraction`, `outline`, `legacy_thread` | `src/agent/zport/agent/` | Native agent as in-process ACP server |
| `agent_servers` | `acp/`, `custom`, `agent_servers` | `src/agent/zport/agent_servers/` | Replaces `acp.zig` client |
| `agent_ui` | `agent_panel`, `message_editor`, `context`, `mention_set`, `profile_selector`, `mode_selector`, `model_selector*`, `conversation_view/`, `agent_diff`, `inline_assistant`, `terminal_inline_assistant`, `threads_archive_view`, `thread_metadata_store`, `thread_import`, `draft_prompt_store`, `favorite_models`, `buffer_codegen`, `terminal_codegen`, `completion_provider`, `unicode_confusables`, … (~40 modules) | `src/workbench/agent_ui/` | GTK workflow translation; flows/keymaps 1:1, internals adapted |
| `context_server` | MCP client/registry | align existing `mcp.zig` | Behavior parity, not blind replacement |
| `prompt_store`, `agent_skills` | prompt/skill management | `src/agent/zport/prompt_store/`, skills parity | Byte-identical prompt outputs |
| `streaming_diff` | diff streaming logic | `src/agent/zport/streaming_diff.zig` | Pure logic port |
| `db` / sqlez | SQLite migrations | `sqlite3` C interop + Zed schema | Zig `@cImport`; schema-identical |
| `agent_settings` / `settings` | agent settings surface | Coral settings schema additions | Exact keys/defaults |
| `sandbox` | OS sandboxing | Linux-path spike | No OS-confinement claims until validated |
| Host (NOT ported) | editor/project/buffer/fs/git/task/lsp | Existing Coral services behind the zport host boundary | The one structural deviation |
| Excluded | `gpui`, `client`, `cloud_*`, `telemetry` (stub), collab | — | Declared in S5/§1 |

Existing Coral `engine/provider/tools/policy/review/store` are **replaced**
where Zed semantics differ (S1/S2/S7); surviving pieces become host adapters.

---

## 5. Technical mapping rules

- **GPUI Entity/Task →** Coral worker threads + event queue + bounded
  `g_timeout` pump; every GTK mutation on the main loop (existing
  `controller.zig` contract).
- **Rust async/await →** explicit state machines + `cancel.zig` tokens;
  preserve Zed's cancellation ordering across streams, tools and RPC waits.
- **Handlebars templates →** build-time precompilation to Zig string tables;
  spike a Handlebars-semantics renderer. Oracle: **byte-identical** rendered
  prompts against upstream fixtures.
- **serde types →** Zig structs + `std.json` with exact field names; SSE
  parsing per provider exactly as upstream.
- **SQLite →** `@cImport("sqlite3")`; port schema and migrations from `db.rs`.
- **Tests →** port Zed logic-level test vectors (provider fake, tool
  semantics, thread state machine); GPUI-coupled UI tests become Coral
  W-story native fixtures.
- **Provenance →** every translated file carries upstream path@commit +
  SHA-256 + modification notice (G0.3).

---

## 6. Phases and exit gates

| Phase | Scope | Exit gate |
| --- | --- | --- |
| **P0 — governance** | G0 license grant; S1–S7 sign-offs; manifest skeleton | License recorded consistently; sign-offs minuted here |
| **P1 — foundation** | Pin audit (hash every ported file at `c84af5b`); `language_model` types + fake provider; `acp_thread` content/event model; SQLite schema; settings | `zport-foundation-unit` parity tests green; manifest complete |
| **P2 — native core** | Thread loop, tool permissions, templates, `native_agent_server`; tools in dependency order: read_file, list_directory, grep, find_path, **edit_file (+edit_session+streaming_diff)**, terminal, diagnostics, fetch, web_search, code actions, rename, definition/references, path CRUD, ask_user, skill, spawn_agent/create_thread | Per-tool parity oracles; end-to-end fake thread; denied tools have no side effect |
| **P3 — providers** | `language_models` provider ports; auth/keychain; **first live-network gate** (opt-in, user endpoints only) | Live tool loop validated per provider |
| **P4 — UI workflows** | Panel, archive/history, mentions, profiles/modes/models, tool cards, agent diff keep/reject, inline assist (editor+terminal), follow, keymaps | W-story fixtures + keymap parity table (`ctrl-n`, `ctrl-shift-r`, …) |
| **P5 — external agents** | `agent_servers` port, registry UI, custom agents, capability-gated UI | Two pinned real adapters; published capability matrix (M7 gate) |
| **P6 — MCP/skills/prompts** | `context_server`, `prompt_store`, `agent_skills` parity | Protocol fixtures (fragmented/malformed/oversized/disconnect) |
| **P7 — hardening** | Sandboxing Linux path, compaction, subagents, cancellation, crash recovery, full parity audit vs pin | Parity audit + RELEASE.md physical/visual/accessibility gates |

**Thinnest end-to-end slice first:** P1 + P2 (read/list/grep/edit/terminal) +
P4 minimal panel → a working Zed-parity thread early; breadth afterwards.

---

## 7. Validation strategy

- Parity oracles per unit; byte-identical prompts; schema-identical
  persistence; wire-identical provider requests.
- Fake ACP/MCP peers first: fragmented frames, invalid schemas, oversized
  payloads, timeouts, disconnects, duplicate/out-of-order responses,
  cancelled requests, process crashes (existing protocol-test culture).
- CI requires no API key or paid service; live gates are opt-in.
- `zig build test` steps named `zport-*-unit` alongside existing suites;
  targeted validation per phase, parent aggregate before release.
- Never run destructive tests against the developer checkout (M0 rule).

---

## 8. Risks and effort honesty

- **Scale:** ~25 tools, ~40 UI modules, multiple providers, a shared thread
  model and SQLite persistence. This is a multi-phase program; **parity
  validation dominates cost**, not the translation itself.
- **Pin drift:** structure was verified at `main` and `agent/src` at the pin;
  P1's hash audit resolves all remaining drift in favor of `c84af5b`.
- **Fidelity risks:** Handlebars semantics, GPUI→GTK focus/IME/virtualization
  gaps, provider API churn, SQLite migration of existing threads.
- **Compliance:** GPL notices/source obligations are continuous, not one-time.
- **Upstream treadmill:** the pin freezes parity; tracking later Zed releases
  is a separate, gated increment (M0 philosophy: pin, don't chase latest).
- **Safety profile changes:** S1 (auto-applied edits) and any S3 reversal
  (trust prompts) materially change the product's risk posture; they are
  recorded, not silent.

---

## 9. Immediate next actions (no code yet)

1. Owner: record the GPLv3 grant (G0) and sign S1–S7.
2. Generate `ZED_PORT_MANIFEST.md` (P1 pin audit, SHA-256 per file).
3. Spikes: Handlebars-semantics renderer, `sqlite3` interop, sandbox Linux path.
4. Begin P1 implementation **only on explicit request** after the above.

Approval state: **not recorded.** This plan is a research/planning output;
product approval and executable parity evidence are separate gates.
