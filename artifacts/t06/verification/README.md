# T06 verification

All commands use exact Zig 0.16.0 and ReleaseSafe. Integration suites run on
disposable Aqueous sessions with private buses, sockets, XDG data and injected
input. No host configuration or desktop state was changed.

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build install test-desktop -Doptimize=ReleaseSafe --summary all
zig build test-surfaces -Doptimize=ReleaseSafe --summary all -- --output artifacts/t06/surfaces
zig build integration -Doptimize=ReleaseSafe --summary all -- --output artifacts/t06/lifecycle
zig build test-components -Doptimize=ReleaseSafe --summary all -- --output artifacts/t06/components
zig build test-adapter -Doptimize=ReleaseSafe --summary all -- --output artifacts/t06/adapter
zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe --summary all
python3 scripts/check-wayland-bindings.py
zig fmt --check build.zig src
```

| Check | Output |
| --- | --- |
| 49 unit/binding tests | [final-build.log](final-build.log) |
| 15 desktop acceptance groups; 2,000-app latency | [desktop.log](desktop.log), [results](../latest/results.json) |
| 17 surface checks, including native Vulkan blur | [surfaces.log](surfaces.log), [results](../surfaces/results.json) |
| Lifecycle and session isolation | [lifecycle.log](lifecycle.log), [results](../lifecycle/results.json) |
| Material gallery | [components.log](components.log), [results](../components/results.json) |
| 21 adapter scenarios | [adapter.log](adapter.log), [results](../adapter/results.json) |
| Fresh-cache generated binding identity | [binding-check.log](binding-check.log) |

[Metadata](metadata.json) records the compiler, clean Aqueous revision, protocol
pins, installed binary hashes, suite binary hashes and frozen DMS reference
hashes. [Source hashes](source-sha256.json) identify implementation and fixture
files. Desktop and surface results match the final installed Pearl/pearlctl.
Lifecycle, gallery and adapter suites passed before the final isolated bar
adjustment to reveal an externally selected workspace; their original hashes
remain recorded. Desktop and surface suites were then repeated successfully.

The [visual comparison](../comparison.html) uses actual unedited captures.
The [overflow capture](../latest/desktop/workspace-overflow-active.png) confirms
the newly active workspace remains visible. Headless timing includes worker
queueing and GTK painting; warm-open timing also includes CLI and observation
overhead. Physical GPU/input latency, extended idle/memory budgets and the full
release soak remain later gates. Aqueous's private Vulkan teardown still reports
the previously documented wlroots shared-buffer allocation diagnostic; Pearl
passes with fatal GTK warnings enabled.
