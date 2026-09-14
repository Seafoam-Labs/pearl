# libpulse ABI (T07)

Zig 0.16.0 translates the vendored **libpulse 17.0-98-gb096** headers into a
module shared by the application and integration targets. `pulse.h` includes
PulseAudio's public API and its GLib main-loop adapter. There is no C source
implementation, bridge, hand-maintained function ABI, or subprocess audio adapter.
Runtime implementation comes from `libpulse` and `libpulse-mainloop-glib`.

The translation-only `glib.h` contains exactly the opaque `GMainContext` typedef
extracted from GLib 2.88.3's `gmain.h`. This avoids translating GLib's inline
functions/macros again (some produce invalid Zig 0.16 translation). All GLib/GIO
functions still use Ghostty's generated modules. Pulse's adapter receives `null`
for GTK's default GLib context, so no duplicate GLib object ABI crosses modules.

[inputs.json](inputs.json) records original header hashes, the extracted type's
source, compiler/target and generated output identity. Upstream copyright/license
notices remain in every header; the [LGPL 2.1 text](../licenses/libpulse-LGPL-2.1.txt)
is included. This lock describes the verified x86_64 Linux GNU environment;
other targets require their own reviewed translation baseline.

```sh
zig build generate-pulse -Doptimize=ReleaseSafe
python3 scripts/check-pulse-bindings.py
```

The export is `zig-out/share/pearl/bindings/pulse.zig`. The checker regenerates in
a fresh local cache and validates inputs/output. Use `--update` only after
reviewing an intentional header/compiler change. Headers are pinned; installed
runtime libraries remain system packages, as with GTK.

## T12 PAM ABI

`pam.h` translates the pinned Linux-PAM application headers under `security/`,
plus system libc identity declarations. Input hashes are in `pam-inputs.json`.
`zig build generate-pam` exports declarations and
`python3 scripts/check-pam-bindings.py` checks reproducibility. The implementation
lives in system libpam; no custom C bridge or privileged Pearl helper is used.
Header copyright/permission notices remain intact and are included in packaging.
