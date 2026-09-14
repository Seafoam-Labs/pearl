# Native Wayland bindings

Pearl generates native protocols directly in Zig using **zig-wayland v0.6.0**,
whose URL/integrity hash is pinned in `build.zig.zon`. GObject/GTK declarations
continue to come from Ghostty's package; there is no custom C bridge or
handwritten Wayland wire marshalling.

[inputs.json](inputs.json) records exact XML source versions, SHA-256 hashes,
requested globals and the generated output hash. Copied XML retains its license
and copyright text. Aqueous's protocol has an MIT SPDX notice; its full permission
notice is retained with the generator and other notices in
[../licenses](../licenses/). The workspace protocol is an input because Aqueous's
shell XML references its handle type; Pearl does not bind a workspace manager
for workspace enumeration. Pearl uses `aqueous_window_info_manager_v1` v3 for layout requests and
the `ext-foreign-toplevel-list-v1` XML type dependency; it does not use that
protocol for duplicate window enumeration. Core XML is also pinned, so system protocol upgrades do not silently
change generated declarations.

Current-master display transactions use the compositor's persistent native IPC
lease and canonical helper commit. The earlier output-management guardian has
been removed. Vendored output-management types remain generated but unbound in
production; they do not constitute a second rollback owner.

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

Idle support uses `ext-idle-notify-v1.xml` from wayland-protocols 1.49, generating notifier
version 1 and core seat version 9. Pearl binds seat version 5 and uses the
inhibitor-respecting `get_idle_notification` request on GTK's Wayland connection.

Clipboard and compatibility capture use `ext-data-control-v1.xml` from wayland-protocols 1.49 and the pinned
Aqueous `wlr-screencopy-unstable-v1.xml`. It generates data-control manager v1,
screencopy manager v3 and core shared memory v1. GTK owns dispatch for both new
services; clipboard payload pipes are separately watched by GLib. See
[clipboard/capture contracts](../../docs/CLIPBOARD_CAPTURE.md).

The master update generates image-copy v1, output and foreign-toplevel image
source managers v1, foreign-toplevel list v1 and Aqueous capture-color v1. The two
ext-image XMLs are pinned to wayland-protocols 1.49; color XML is pinned to Aqueous
`1d038dc3bafa0044d9599f8f51f84105a6a85bb3`. The foreign list is used only for
capture-source identity; the desktop window model continues to use canonical IPC.
Per-frame color metadata is mandatory on the native capture path. Interfaces,
listeners and lifetimes live entirely in Zig on GTK's Wayland connection.
