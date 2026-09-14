# Native Wayland bindings

T05/T06 generate native protocols directly in Zig using **zig-wayland v0.6.0**,
whose URL/integrity hash is pinned in `build.zig.zon`. GObject/GTK declarations
continue to come from Ghostty's package; there is no custom C bridge or
handwritten Wayland wire marshalling.

[inputs.json](inputs.json) records exact XML source versions, SHA-256 hashes,
requested globals and the generated output hash. Copied XML retains its license
and copyright text. Aqueous's protocol has an MIT SPDX notice; its full permission
notice is retained with the generator and other notices in
[../licenses](../licenses/). The workspace protocol is an input because Aqueous's
shell XML references its handle type; Pearl does not bind a workspace manager
in T05. T06 adds `aqueous_window_info_manager_v1` v3 for layout requests and
the `ext-foreign-toplevel-list-v1` XML type dependency; it does not use that
protocol for duplicate window enumeration. Core XML is also pinned, so system protocol upgrades do not silently
change generated declarations.

T11 adds `zwlr_output_manager_v1` v4 and `wl_output` v4 for the independent
display-preview guardian. The guardian uses its own connection, tests before
apply, and restores only unchanged candidate heads under a current serial.
The vendored output-management XML retains its upstream permission notice.

Ordinary builds generate into Zig's cache and import that module. To export the
single generated source for inspection:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build generate-wayland
# zig-out/share/pearl/bindings/wayland.zig
python3 scripts/check-wayland-bindings.py
```

The script verifies all vendored inputs, regenerates with a fresh temporary local
cache and compares output SHA-256. First-time dependency downloads still require
network access. For an intentional protocol update, review the XML and notices,
update its source/hash in the manifest and the requested versions in `build.zig`,
then run `--update` to record the generated hash. Run the normal check again and
repeat surface/blur validation. Do not edit generated declarations.
