# Writing a Pearl component

Start with the [step-by-step plugin development guide](../docs/PLUGIN_DEVELOPMENT.md)
to build a clickable widget. See the [runtime and API reference](../docs/PLUGINS.md)
for setup, limits and verification.
The public contract is `wit/plugin.wit`; `sdk/c/plugin.{c,h}` are unmodified
output from wit-bindgen 0.62.0. `build-examples.py` regenerates and checks them.
The Rust example uses wit-bindgen's Rust macros and a locked freestanding
allocator. The Zig example imports the generated C header and links its glue.
No handwritten language-specific protocol exists in the Pearl host.

A package is a directory containing `plugin.json`, `plugin.wasm` and declared
PNG assets. The component must export `pearl:plugin/guest@0.1.0.handle-event`.
It may import the matching Pearl host interface and its type definitions only;
standard WASI imports are deliberately unavailable. For Rust, `no_std` alone
is insufficient: disable wit-bindgen's default `std` feature and provide an
allocator/reallocation export, as in the example. Standard-library WASI output
is rejected instead of receiving implicit system access.

`handle-event` receives activation with validated effective settings, button
clicks, timers and explicit previews. One guest instance serves all its views.
Settings/permission changes restart that instance; no guest state survives a
restart unless represented in host settings. There are no output/window handles.

- `publish(scene)` submits one complete scene per callback. Node IDs must be
  unique. Labels/buttons use plain text; images reference assets or clips from
  this package. The scene commits only if the guest callback succeeds.
- `set-timer(ms)` sets the next one-shot timer after the callback. Zero cancels;
  valid nonzero delays are 100–86,400,000 ms. Set it again on each timer event to
  repeat. A callback that does not change the timer retains the requested delay.
- `input-activity(subscribe)` currently returns `permission-denied` or
  `unsupported`. Preview is synthetic and never represents another application's
  input. Don't advertise global typing support until this reports available.
- `log(text)` validates bounded diagnostic text; the current host discards it
  rather than writing arbitrary guest content to the desktop journal.

Call failures are fatal to the current instance. Publication, timers and
capability availability are synchronous bounded imports. A plugin cannot provide
GTK markup, CSS, scripts, arbitrary images/URLs or native UI pointers. Asset
loading, clipping, display scaling and animation belong to Pearl.

See `src/plugins/model.zig` for manifest/schema limits, `docs/PLUGINS.md` for
runtime budgets and the original roadmap for future contract extensions. The API
is experimental; incompatible changes will require a new WIT package version.

The original companion SVG and resulting PNG are CC0-1.0; its asset license is
packaged beside the example. Generated bindings come from the upstream
wit-bindgen project (Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT).
