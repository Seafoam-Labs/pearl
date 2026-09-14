# Pinned Aqueous master evidence

Pearl **1.0.0-rc.2**, Zig **0.16.0**, Aqueous `1d038dc3bafa0044d9599f8f51f84105a6a85bb3`, helper **0.8.0**.

[UI capture gallery](gallery.html) · [capability coverage](../../docs/AQUEOUS_CAPABILITY_COVERAGE.md) · [upstream dependencies](../../docs/AQUEOUS_MASTER_DEPENDENCIES.md) · [migration](../../docs/AQUEOUS_MASTER_MIGRATION.md)

| Evidence | Recorded status |
|---|---|
| [Full functional matrix](functional/metadata.json) | passed |
| [Themes, allocation, accessibility names/roles and keyboard](ui/metadata.json) | passed |
| [Canonical journal and native lease adversarial suites](upstream/metadata.json) | passed |
| [Production idle/startup and 1,000-cycle soak](performance/metadata.json) | passed |
| [Two fresh source/build roots](reproducibility/metadata.json) | passed |
| [Checksum-locked Arch package](package/metadata.json) | passed |

The [release gate](gate.json) checks matching production binaries, provenance, source stability, fixture hashes, coverage, all automated suites and separate human signoffs. It remains closed for: project-license, direct-login, uwsm-login, visual-review, physical-displays, physical-security, hardware-services, accessibility, presentation-performance.

Production helper/compositor hashes and build flags are in [provenance.json](provenance.json). Its patch list records the pinned source inputs; patched wlroots was reused read-only, not rebuilt here. Instrumented crash fixtures are labelled separately in the upstream report and are never packaged.

All sessions use private HOME/XDG directories, D-Bus buses and virtual outputs. A separate test-only focus query observes GTK while actual keyboard events perform edits. Direct AT-SPI focus requests return an error on this GTK stack; names/roles are verified, while real Orca/physical acceptance remains pending.

Current master cannot safely persist unclassified collection changes, lacks several structured display mutations, and withholds scene color metadata. Pearl exposes these as explicit gates. This evidence does not claim successful physical preview, HDR conversion or isolated-window PNG export.

Earlier `artifacts/t16` is preserved as the previous candidate. Intermediate diagnostic runs under this directory are not substitutes for the indexed final suite metadata.
