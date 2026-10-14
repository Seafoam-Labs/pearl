# Distribution runtime setup validation

October 14, 2026. Settings now provides **Set up runtime (install if needed)**.
It checks installed runtimes first, then installs the repository runtime through
Shelly on Devario or pacman on Arch/Arch derivatives. GPU selections request the
Vulkan or CUDA backend package. Versions remain capability checked and unpinned.

- [Build and unit tests](build-and-unit.log): 391/391 pass; production Settings
  and assistant build. Zig tests cover distribution precedence, fixed package
  arguments, backend selection, reuse, missing/custom runtime fallback, failed
  installation, incompatible post-install runtime and cancellation. Install
  fixtures do not authenticate or modify the host package database.
- [Native Settings/launcher report](launcher-final/report.json): 10 checks pass,
  including setup reusing a compatible runtime without installing packages or
  changing the settings draft, discovery, local model checks, CPU/Automatic
  draft isolation, active-answer Apply confirmation and assistant shutdown.
- [Native settings screenshot](launcher-final/session/runtime-acceleration-settings.png).

The native test uses a private headless Aqueous session, existing LFM2.5-350M
weights and a local search fixture. No live package transaction was performed;
real Shelly/pacman authentication, downloads and GPU drivers remain to be tested
on disposable Devario/Arch systems. Package names follow the current official
Arch llama-cpp/ggml packages; Shelly's `install standard --needed` syntax was
checked against the local Devario Shelly 3.1.6 source archive. This does not pin
either Shelly or llama.cpp to that version.

The installer launches fixed arguments without a shell and leaves package
confirmation enabled. It does not forcibly cancel a transaction when Settings
closes, and never changes repositories or initiates a system upgrade. A failed
or cancelled installation leaves the runtime selection unchanged.
