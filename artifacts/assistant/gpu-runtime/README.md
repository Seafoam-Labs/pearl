# Assistant runtime and GPU update validation

Experimental implementation, October 14, 2026. The assistant accepts compatible
system, private-package and custom llama.cpp executables without a pin manifest.
Native settings expose CPU, Automatic and selected GPU modes, Vulkan/CUDA
selection, local compatibility checks, memory targets and CPU fallback.

## Passing checks

- [Build and unit log](build-and-unit.log): production shell, agent, settings and
  CLI plus instrumented frontends build; all 388 core/assistant/transitive tests
  pass. Tests include preference migration, device matching, capability parsing,
  memory fields and canonical tool-result reuse.
- [Native launcher and settings report](launcher-final/report.json): real
  keyboard handoff and floating chat, runtime discovery, local model/tool checks
  without provider requests, CPU/Automatic draft isolation, Stop & apply during
  an active answer, and disabling the assistant through Settings.
- [Real model report](real-cpu-final/report.json): actual LFM2.5-350M Q4 tool
  call, Google-through-SearXNG fixture, cited summary, follow-ups, hide/resume,
  lock/clear cancellation and parent-disconnect cleanup, using the newly built
  optional CPU runtime.
- [Relocated runtime report](real-cpu/report.json): the same real-model flow
  using a custom executable under a path with spaces, with no `runtime.json`.
- [Runtime protocol report](protocol-final/report.json): simulated GPU offload,
  two arbitrary build identifiers, missing authentication/capabilities,
  executable replacement, startup failure, mid-answer device loss, unverified
  offload and cancellation. GPU recovery makes exactly one provider request,
  including when the retried model repeats an equivalent search with different
  JSON whitespace. These are simulated devices, not hardware measurements.

The optional source-tree build completed for CPU and staged its actual shared
libraries/SONAME entries successfully. The source was llama.cpp v0.6.0 commit
`d81235049384534c167caea52b85a694f6103d14`, selected explicitly for this test.
This is a regression fixture, not an accepted-version restriction. See
[source build log](source-build.log). Missing source arguments and an incorrect
archive SHA256 failed with actionable errors before compilation:
[missing source](missing-source.log), [incorrect checksum](incorrect-checksum.log).

## Native screenshots

- [Runtime and acceleration settings](launcher-final/session/runtime-acceleration-settings.png)
- [Stop and apply confirmation](launcher-final/session/stop-and-apply.png)
- [Floating conversation](real-cpu-final/conversation.png)

The screenshots are from a private headless Aqueous session, with separate
HOME/XDG and D-Bus. No installed desktop, user settings, paid search credentials
or public Google endpoint was changed or used.

## Measurement scope and remaining qualification

The final CPU fixture's cold answer took 2.416 seconds on this host. After the
answer, RSS was 69,040 KiB for the agent and 463,808 KiB for the runtime
(approximately 520 MiB combined). These snapshots exclude the rest of the
desktop and do not establish a whole-system peak or low-end CPU guarantee.

This environment has no `/dev/dri` devices. Real Vulkan/CUDA builds and execution,
GPU memory release/pressure, AMD/Intel shared-memory accounting, physical device
identity across driver changes, and delegated cgroup enforcement require hardware
qualification. There was no delegated memory cgroup in these tests; the reported
policy correctly remained best effort. A second independently packaged upstream
release, older CPUs/AArch64, Q8_0 and the 6 GiB desktop target remain release gates.

The portable runtime device listing lacks physical UUIDs. Selection matches
backend/description/capacity and rejects indistinguishable duplicates. Checks
repeat on every new load instead of persisting unverified driver/library cache
entries. GPU memory targets are estimates; host RSS monitoring and a delegated
cgroup, when available, are not a hard VRAM boundary.

The small model's factuality limitations remain. Valid citation IDs do not prove
that generated claims follow from sources. The human-reviewed answer-quality
evaluation remains necessary before broader reliability claims.

## Reproduction

Use an existing model and a patched test compositor. No test downloads a model.

```sh
zig build test test-agent build-agent build-agent-test build-settings build-ctl
zig build test-agent-launcher -- --model /path/to/LFM2.5-350M-Q4_K_M.gguf \
  --aqueous /path/to/patched/aqueous
python3 tests/integration/test_agent_runtime.py \
  --model /path/to/LFM2.5-350M-Q4_K_M.gguf --aqueous /path/to/patched/aqueous
python3 tests/integration/test_agent_ui.py \
  --model /path/to/LFM2.5-350M-Q4_K_M.gguf \
  --runtime /absolute/path/to/llama-server --aqueous /path/to/patched/aqueous
```
