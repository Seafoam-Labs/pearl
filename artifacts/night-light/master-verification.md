# Aqueous master verification

Verified September 19, 2026 against remote master
`cf6c4dcd649421184611d399f19cbeeb4acb4a0e` (`added warming protocol`).
`git ls-remote` confirmed that the clean local Aqueous checkout matches the remote.
Pearl's existing, uncommitted native adapter changes were included in this check.

The native software integration works in the tested private environment. The
full Night Light plan is **not complete for production physical displays**.

| Check | Result |
| --- | --- |
| Pearl ReleaseSafe build | 31/31 steps passed |
| Night Light feature target | 162/162 pure/clock tests and 12 private integration groups passed |
| Protocol/source consistency | Vendored XML matches master; all source hashes in Aqueous's warming validation record match the inspected files |
| Native headless Vulkan runtime | Rendered warming/restoration, output isolation, contention, client crash, commit fallback, modeset and mirror transitions passed |
| Freshly built Pearl in native runtime | Saved policy, two committed output temperatures, off/on and crash restoration passed |
| Default production compositor on headless pixman | Unqualified snapshots and acquisition denial passed |

The runtime checks used existing private and production Aqueous builds from
`/tmp/aqueous-warming`, with the patched wlroots prefix there. Their build policies
respectively enable and disable warming testing. These binaries were not rebuilt
in this verification; source consistency was checked against the upstream
validation record. [Provenance and binary hashes](master/verification.json),
[feature log](master/night-light.log), [native log](master/native.log),
[production-denial log](master/production.log), and
[Pearl's active snapshot](master/native/pearl-active.json) are retained.
The native captures show [baseline](master/native/baseline.png),
[warming](master/native/warmed.png), and [restoration](master/native/restored.png).

Remaining acceptance:

- Aqueous's production qualification set is empty. Physical SDR warming,
  restoration, VT/DPMS/hotplug/device-loss and compositor-death behavior require
  hardware validation. HDR and arbitrary calibration are unsupported.
- `packaging/release.json` still pins Aqueous `8858724`; the matching new compositor
  and patched wlroots must be integrated and release metadata revalidated.
- The new runtime suite covers Pearl with two eligible outputs. It does not
  establish every Pearl-specific mixed-output, hotplug, suspend or asynchronous
  transition scenario listed in Stage 5. Native fixture coverage of compositor
  transitions is not equivalent to full shell lifecycle coverage.

The earlier broader Settings regression results and pre-existing Services Apply
timeout remain recorded in [the original verification](README.md). They were not
rerun as part of this master check. No physical qualification or release pin was
changed by this verification.
