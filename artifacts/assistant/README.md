# Experimental assistant acceptance — 2026-10-14

All sessions used a private HOME/XDG, D-Bus, headless Aqueous and local search
fixture. No real Google query or paid search credentials were used. The Google
adapter was checked for `engines=google`. Runtime/model downloads were explicit
preparation, not part of typing, enabling preferences or running these tests.

- [Real launcher and Settings report](launcher/report.json): disabled defaults,
  calculator/exact-app priority, no inference while typing, keyboard Enter and
  acknowledged handoff, 440 × 560 floating window, focus independence, CLI
  controls, and native Settings Apply disabling the agent.
- [Chat/runtime report](latest/report.json): actual Q4 model tool call, cited
  result, follow-up history, hide/resume, lock cancellation/unload, clear while
  generating, and parent-disconnect shutdown.
- [Existing calculator regression report](calculator-regression.json): passed
  unchanged calculator, copy, stale-input and IME acceptance tests.
- [Launcher screenshot](launcher/session/launcher-question.png)
- [Settings screenshot](launcher/session/assistant-settings.png)
- [Conversation screenshot](latest/conversation.png)

The final native build and `zig build test-agent test` passed: 84 assistant and
transitive policy tests, 281 core tests and 15 additional tests (380 total).
The runtime was built from llama.cpp v0.6.0 commit
`d81235049384534c167caea52b85a694f6103d14`; the runtime recipe and manifest are
in `packaging/assistant`. The narrow floating patch was applied and compiled
in a temporary Aqueous checkout, not the installed compositor.

The final local-fixture cold answer took 2.013 seconds. After the answer, Linux
reported 68,016 KiB resident for the agent and 462,984 KiB for its runtime
(about 519 MiB together). These are process snapshots on this test host, not
full-session peak RAM or a low-end hardware guarantee. Inference uses two
workers; HTTP and housekeeping threads are also present.

The 350M model produced the initial supported summary, but its follow-up
answers were sometimes indirect or misleading. Syntax-valid citations do not
prove factual support. The 100-question human-reviewed evaluation, Q8_0/live
provider qualification, and older CPU/AArch64/6 GB desktop measurements remain
release gates. This implementation is explicitly experimental.

The older `test-settings-integration` installer suite could not reach its UI
checks: its staging fixture omits `xdg-desktop-portal-pearl`, which the existing
portal installer requires. Its fixture now includes the new assistant binary;
the separate assistant launcher/settings acceptance above passes. Full installer
qualification is not claimed by this report.
