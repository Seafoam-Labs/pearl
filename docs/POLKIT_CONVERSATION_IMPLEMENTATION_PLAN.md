# Polkit authentication conversation implementation plan

Status: production flow implemented; test fixture work, automated test runs, and
hardware acceptance are deferred until after release at the user's request.

Addresses [issue 29](https://github.com/Seafoam-Labs/pearl/issues/29), investigated
against Pearl `fb0c91f`. A single-identity authorization request should start the
configured authentication conversation immediately after Pearl's input privacy
gate is ready. A touch-only security key flow must work without pressing Enter;
passwords, PINs, and other answers should be requested only when PAM asks for them.

## Cause and scope

At the investigated revision, `src/services/polkit.zig`'s `begin()` created a live
password field and displayed “Enter your password to continue.” `activityReady()`
presented the window, but `submit()` was the only path that created and initiated
`PolkitAgentSession`.
This explains the reported transition from a password-looking dialog to a
YubiKey cue after pressing Enter. `requested()` also submitted any text typed
before the first secret request, and `completed()` assumed failures required a
password retry.

Polkit's helper starts the `polkit-1` PAM service. Pearl's locker uses a separate
service, packaged as `pearl-git` in the Arch git package. This change belongs in
the polkit agent's presentation and conversation lifecycle; authentication
ordering continues to come from the administrator's PAM configuration.
See the [polkit 127 helper source](https://github.com/polkit-org/polkit/blob/127/src/polkitagent/polkitagenthelper-pam.c#L189-L193)
and [PolkitAgentSession API](https://polkit.pages.freedesktop.org/polkit/PolkitAgentSession.html).

Keep production authentication through libpolkit-agent and its trusted helper.
Do not add FIDO device discovery, parse prompt text to identify authentication
methods, modify PAM stacks, or change the locker and greeter in this fix.

## Required interaction

| State | Presentation and action |
| --- | --- |
| Waiting for privacy gate | No conversation starts and no input can be submitted. |
| One identity and gate ready | Present neutral status and start the conversation once. |
| Multiple identities and gate ready | Show the identity picker and Authenticate action; start after the user confirms the selected identity. |
| Conversation processing or awaiting touch | Display backend information; hide and disable the answer field and disable submission. Cancel remains available. |
| Backend requests an answer | Show its actual prompt, clear and enable the answer field, honor the echo flag, and focus the field. Enable submission. |
| Answer submitted | Clear and disable the field before forwarding one response; wait for the next backend event. |
| Authentication failed | Show neutral failure text and a Try again action; a click starts a fresh conversation. |
| Identity changed | Cancel the old conversation, clear its answer and messages, and return to explicit confirmation for the new identity. |
| Authentication succeeded or cancelled | Complete the outstanding request once and release all conversation and UI resources. |

Information and error messages require no response. Use a status label separate
from the active question so an informational event cannot obscure an unanswered
PIN/password prompt. Keep backend messages as bounded plain text. Focus Cancel
or the identity selector when no answer is requested; info updates should not
steal focus. Use neutral entry labeling such as “Response”, with input purpose
matching the echo mode, and expose the active question accessibly.

## Implementation sequence

### 1 Add controlled conversation coverage

Deferred until after release. The production change continues to use
`PolkitAgentSession` directly; the adapter below is planned test infrastructure.

- [ ] Introduce a small conversation adapter around session creation, event
  delivery, response, and cancellation. Production delegates to the current
  `PolkitAgentSession` API. An instrumented build can select a scripted backend
  that delivers the same events asynchronously through the main loop.
- [ ] Compile fixture selection and controls only into builds with
  `build_options.test_hooks`. The production binary must have no fixture
  success path or arbitrary helper override. Keep the adapter scoped to this
  agent rather than creating a general authentication framework.
- [ ] Extend `tests/fixtures/session_security.py` to offer one or multiple
  identities and distinct request cookies. Extend `tests/integration/test_security.py`
  to drive scripted conversations and inspect prompt visibility, echo mode,
  button state, and lifecycle outcomes. Record event order and counts without
  recording credentials or real cookies.
- [ ] Add the issue reproduction first: after a single-identity request, expect
  conversation startup and a touch instruction without any keyboard or button
  input. Establish that the current delayed-start behavior fails this check.

The existing authority fixture tests registration, identity handling, and
cancellation; its private PAM module exercises the locker. `PEARL_TEST_PAM_DIR`
does not redirect the system polkit helper. Scripted polkit tests must therefore
avoid starting the host helper or relying on host PAM settings. They establish
agent behavior, while real polkit/PAM acceptance remains a separate check.

### 2 Start conversations at the correct lifecycle boundary

- [x] Extract `startConversation()` from `submit()`. Require a pending request,
  an allowed and registered session, a completed privacy gate, a valid selected
  identity, and no existing conversation. Connect handlers before `initiate()`.
- [x] Call it from `activityReady()` after presenting the single-identity UI.
  Keep multiple-identity startup behind Authenticate. Reuse it for Try again.
- [x] Give conversation state one explicit representation, sufficient to
  distinguish choosing an identity, processing, awaiting an answer, and retry.
  Avoid conflicting combinations of state and the existing `waiting` flag.
- [x] Make submission answer only a pending backend request, or perform the
  explicit start/retry action. Duplicate Enter/click events while processing
  must neither start another session nor send another answer.
- [x] Preserve cancellation on Escape, close, authority loss, session inactivity,
  lock, shutdown, and the existing 120-second request deadline. Retrying or
  switching identity must not extend that deadline.

### 3 Make presentation follow backend events

- [x] Replace the initial password field and password-specific status with the
  states above. Retain references to the submit button and separate status and
  question labels; clear these references in cleanup.
- [x] Enable the answer field only in `requested()`, using the supplied prompt
  and echo flag. Remove speculative password submission and the hard-coded
  Password placeholder. Clear answers between questions as well as attempts.
- [x] Display info/error events without sending `response()` or changing the
  meaning of an outstanding question. A cue alone must never enable submission.
- [x] On failure, offer Try again without guessing which credential is needed.
  On identity changes, disconnect and cancel the old session before clearing
  state. Guard callbacks with the active session identity or attempt generation
  so stale events cannot affect a replacement conversation.
- [x] Retain response-buffer zeroing, bounded text, and single completion of
  the deferred D-Bus invocation. Handle immediate initiation failure without
  touching UI or session objects already released by a completion callback.

### 4 Validate and document

- [ ] Run the matrix below against the real GTK agent with the scripted backend.
  Keep existing authority and locker security checks passing.
- [ ] Extend `tests/integration/test_plugin_activity.py` to assert conversation
  initiation occurs only after the privacy gate, including delayed/missing
  acknowledgement, cancellation before readiness, and overlapping lock flows.
- [ ] Update build wiring if the adapter requires a fixture module. Retain
  coverage under existing suite IDs; update `scripts/test-suites.json` source
  inventory if adding test files.
- [x] Update `docs/SESSION_SECURITY.md` with automatic single-identity startup,
  explicit identity choice, backend-driven prompts, and the distinction between
  polkit and locker PAM services.
- [x] Build production and instrumented variants.
- [ ] After adding the scripted backend, verify production cannot select it.
  Capture representative GTK states and record real-device acceptance
  separately from fixture results.

## Regression matrix

| Scenario | Required assertion |
| --- | --- |
| Touch cue followed by success | Starts automatically for one identity; no answer field, Enter, or response call; closes exactly once. |
| Password or secret PIN | Prompt appears automatically; text is masked; only an explicit answer reaches the backend. |
| Visible question | Echo is enabled only as requested; previous secret content is absent. |
| Multiple questions or info between questions | Correct current prompt and status; one response per answered question; no credential reuse. |
| Error/info while awaiting an answer | Active question remains identifiable; message alone sends no response. |
| Failure and retry | Neutral failure UI; no automatic retry loop; one fresh session after Try again. |
| Multiple identities | No initiation before confirmation; switching cancels and clears the prior attempt. |
| Stale event after switch/cancel | No UI change, duplicate reply, or access to released resources. |
| Cancel, timeout, authority restart, inactivity, lock | Conversation and request terminate once; entry is cleared; privacy token is released correctly. |
| Repeated Enter/click | No duplicate initiation or response while processing. |
| Privacy acknowledgement pending | Zero conversation starts until readiness; cancellation prevents a deferred start. |
| Initiation failure or immediate completion | Valid retry/closed state with no use-after-free or dangling callbacks. |

Use the repository runner to check prerequisites and run the affected suites:

```sh
python3 scripts/test.py doctor --suite test-security --suite test-plugin-activity
python3 scripts/test.py run --suite test-security --suite test-plugin-activity
```

If prerequisites are missing, use the runner's preparation workflow from
`docs/TESTING.md` and report remaining blockers. These suites do not prove
physical security-key authentication.

## Acceptance criteria

- [ ] With an existing touch-only `polkit-1` PAM configuration, trigger an action
  that actually requires authorization, such as `pkexec /usr/bin/true`. The
  single-identity dialog shows the configured cue without Enter and completes
  after touching the key. Avoid cached authorization when checking this.
- [ ] Verify an existing password configuration and, where available, a
  configured PIN or multiple-factor flow. Pearl follows every backend question
  and does not treat a successful individual factor as final authorization.
- [ ] Verify failed authentication, retry, and cancellation on the real helper;
  record package versions and tested configuration without credential material.
- [ ] All affected automated checks pass and representative layouts remain
  usable with keyboard navigation and long prompts. Record unavailable hardware
  checks explicitly; do not label fixture success as hardware acceptance.

The release change contains the agent implementation and security-document
update. Complete the deferred fixture coverage and acceptance checks after
release; implementation checkboxes above do not claim runtime validation.

## Build verification

Both compilation commands completed successfully with Zig 0.16.0:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe -j2
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build build-integration -Doptimize=ReleaseSafe -j2
```

Formatting and whitespace checks passed. No test suites or interactive
authentication checks were run; the instrumented binary was compiled only.
