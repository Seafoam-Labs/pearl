# Zig / WebAssembly Component Model feasibility probe

Investigated September 18, 2026 for the
[implementation plan](../../docs/WASM_PLUGIN_IMPLEMENTATION_PLAN.md).
This standalone probe does not modify or run Pearl, GTK, a desktop session or
host configuration. It is not wired into the production build.

## Pinned tools

- Host and guest compiler: Zig 0.16.0, using its bundled C compiler for `guest.c`.
- [Wasmtime 48.0.2 Linux x86_64 C API archive](https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.2/wasmtime-v48.0.2-x86_64-linux-c-api.tar.xz).
  SHA-256: `d9a2b5dfaf688035f288a7ae81a4b96c3acdd3e849262c2ab577b61908c3f9f9`.
- [wasm-tools 1.259.0 Linux x86_64 archive](https://github.com/bytecodealliance/wasm-tools/releases/download/v1.259.0/wasm-tools-1.259.0-x86_64-linux.tar.gz).
  SHA-256: `3e9b374b4c7715b771b69bf0d65a337990ed4546ec5e97e01c0ff587dfc52160`.

Official release downloads were checked against the SHA-256 digests supplied
by GitHub release metadata and extracted into `/tmp/pearl-wasm-feasibility`.
No tool was installed globally and no downloaded binaries are committed.

## Reproduce

Download, verify and extract the archives above to a scratch directory. From
the Pearl repository, substituting the actual paths:

```sh
python3 spikes/wasm-plugins/reproduce.py \
  --wasmtime-prefix /tmp/pearl-wasm-feasibility/wasmtime-v48.0.2-x86_64-linux-c-api \
  --wasm-tools /tmp/pearl-wasm-feasibility/wasm-tools-1.259.0-x86_64-linux/wasm-tools \
  --output /tmp/pearl-wasm-feasibility/probe
```

The script downloads nothing. It copies the probe sources to the output directory,
compiles C and Zig guests to core Wasm, prints their generated modules using
`wasm-tools`, and constructs component wrappers. Its native Zig host translates
the released C headers through `addTranslateC` and links `libwasmtime.so` with a
scratch-directory RPATH. Component text is converted to binary through Wasmtime
before instantiation. Each check receives its own store and linker.

## Observed output

```text
PASS C guest -> Zig callback -> 42
PASS Zig guest -> Zig callback -> 42
PASS missing import: undeclared host import rejected
PASS canonical string result and cleanup
PASS linear memory growth capped at 1 MiB
PASS execution budget: infinite loop stopped by fuel
```

The arithmetic guest calls a host increment function then adds one itself;
input 40 must produce 42. The string and failure probes use hand-written WAT.
The memory check confirms rejected `memory.grow`, not total resident memory
control. The loop check confirms a fuel-related error, not a generic failure.

## Findings and limits

- Released Component Model hosting works directly from Zig 0.16; a Rust helper
  or handwritten C bridge was not needed for these checks.
- Both tested guest languages use the same component contract and host callback.
- The 48.0.2 call implementation requires initialized result slots in practice:
  using `undefined` crashed in value destruction, while zero initialization passed.
  The final source initializes slots and releases owned results/errors.
- This is a manually wrapped scalar contract, not a generated WIT SDK. It does
  not prove compatibility with arbitrary C/Zig programs or standard libraries.
- WASI is not registered. Guest filesystem, sockets, environment, GTK and shell
  APIs are not exposed. Restricted WASI P2 policy is future validation work.
- No resource handles, generated rich-type bindings, process supervisor, GTK
  views, real-session behavior, adversarial suite, RSS benchmark or other CPU
  architecture were tested. Those gates are explicit in the implementation plan.
