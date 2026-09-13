# Pearl

Pearl is the working name for a planned **Zig 0.16 + GTK4 desktop shell built exclusively for Aqueous**, with a look and feel closely modeled on Dank Material Shell.

T00–T05 are implemented. The pinned Zig 0.16.0 stack has generated
layer-shell/session-lock bindings, an application lifecycle, compiled GTK
resources and a demo gallery. Private Aqueous tests cover startup, shutdown,
cancellation and session isolation. A bounded Aqueous decoder and atomic state
model pass pure protocol tests. The gallery now includes dark/light Material
components, compact density, larger text, translations and virtualized search.
Session mode now maintains two Aqueous connections with validated commands,
reconnect recovery and bounded window icons. Session surfaces now include per-output
wallpaper and bar, modal popup, click-through OSD and frame reservations, native
Aqueous blur and the session-scoped `pearlctl` CLI. T06 is next: the first complete
bar/launcher/control-center slice. The full shell remains in progress.

- [Implementation plan](docs/IMPLEMENTATION_PLAN.md): scope, visual design, architecture, integration contracts, release gates, and risks.
- [AI implementation tasks](docs/TASKS.md): ordered work packages with dependencies, concrete deliverables, and acceptance criteria.
- [Compatibility and reproduction](docs/COMPATIBILITY.md): verified dependencies, commands, capability gaps and baseline results.
- [Development guide](docs/DEVELOPMENT.md): run the gallery, use isolated sessions, and follow lifecycle/ownership conventions.
- [Aqueous model](docs/AQUEOUS_MODEL.md): decoder limits, atomic updates, derived views and ownership contracts.
- [Aqueous adapter](docs/AQUEOUS_ADAPTER.md): persistent connections, command completion, recovery and icon caching.
- [Surfaces and CLI](docs/SURFACES.md): output identity, reservations, popup/input policy, native blur and control v1.
- [Components](docs/COMPONENTS.md) and [DMS visual comparison](artifacts/t03/comparison.html): gallery controls, keyboard behavior and captured differences.
- [Generated bindings](bindings/README.md): full layer-shell/session-lock namespaces sharing Ghostty's GTK types, with no C bridge.
- [Progress](docs/PROGRESS.md) and [visual references](artifacts/t00/REFERENCES.md).

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
```

To see the gallery inside a separate compositor window on your Wayland desktop:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build gallery -Doptimize=ReleaseSafe -Ddev-backend=nested
```

See the development guide for prerequisites and test commands. The T00 spike
remains a test executable; the application is not yet a complete desktop shell.

Start with the plan's product brief, then use the task list to implement one verifiable slice at a time. The plan is based on local Aqueous and DMS source inspected on September 13, 2026, plus upstream GTK and Ghostty documentation.
