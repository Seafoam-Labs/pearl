# Pearl GTK bindings

Pearl uses Ghostty's generated GObject package for GTK, GDK, GLib, GIO,
GObject and Pango. The package does not contain gtk4-layer-shell or
gtk4-session-lock. Those missing namespaces and the Polkit/PolkitAgent namespaces are generated in this directory. T12 uses polkit 127 GIR inputs for a real authentication agent.
There is no Pearl C bridge. T05/T06 additionally generate native core, background-effect, Aqueous shell
and window-info/layout declarations using pinned zig-wayland/XML inputs; see
[protocols/README.md](protocols/README.md). T07 adds the translated libpulse/GLib
main-loop ABI from [pinned headers](headers/README.md). T12 adds pinned Linux-PAM application headers (`generate-pam`, `scripts/check-pam-bindings.py`) and ext-idle-notify. PAM libc identity declarations use system libc headers. Polkit/PAM notices are preserved under `licenses/`.

## Pinned inputs

- Zig: **0.16.0**, enforced by `build.zig` and recorded in `.zigversion`.
- Ghostty artifact: `https://deps.files.ghostty.org/gobject-2026-07-28-36-1.tar.zst`.
- Generator: `jcollie/zig-gobject` commit
  `4ff7b4d030465b50796b90af72fec41eb9b3b5c6`, the generator selected by the
  inspected Ghostty binding repository.
- Exact package integrity hashes: [build.zig.zon](../build.zig.zon).
- Root GIRs: [gir/](gir/), copied from gtk4-layer-shell **1.3.0**.
- Transitive GIR input hashes: [gir-inputs.json](gir-inputs.json).

The generated modules expose the complete GIR namespaces: layer/edge/keyboard
enums, version/support queries, all window configuration functions, and the
session-lock instance with monitor, locked, failed and unlocked signals.
These are ABI bindings to the installed library; the implementation still lives
in `libgtk4-layer-shell`. GIR-unexposed internal library APIs are not generated.

`build.zig` connects their imports to the **same module instances** used by the
Ghostty package. It does not use the generator's separate GTK/GDK copies. A GTK
window from Ghostty therefore has exactly the type expected by both new APIs.

## Build and regenerate

Normal builds use the checked-in generated files and do not need a GIR generator:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-bindings -Doptimize=ReleaseSafe
```

For generation, install `xsltproc` and the system GIR files matching the lock,
then run:

```sh
python3 scripts/generate-bindings.py --check
python3 scripts/generate-bindings.py
```

The script builds the pinned generator, applies its shipped fixes/overrides,
verifies every GIR input and checks the resulting file set and bytes. It copies
`gtk4layershell1`, `gtk4sessionlock1`, `polkit1` and `polkitagent1`. Package downloads require network
access on the first build; Zig verifies their hashes.

For an intentional dependency update, replace the root GIRs if needed, review
the system GIR changes, then run `--update-input-lock`. Review the generated
diff, rerun the type tests and isolated integration harness, and update the
compatibility matrix. Do not edit generated `.zig` files directly.

The shared library must load before GTK/Wayland for its interposition to work.
Pearl links `gtk4-layer-shell-0` before `gtk4`; the T00 ELF record confirms this
order. `gtk4-layer-shell-0` is the pkg-config name on the tested system.

## Notices

[licenses/](licenses/) preserves the Ghostty fork's MIT notice, the generator's
0BSD notice, and gtk4-layer-shell's MIT notice for the copied GIR documentation.
The downloaded Ghostty artifact itself omits a license file; its upstream fork
notice is retained here explicitly.
