# Build your first Pearl plugin

This guide takes you from a small C source file to a clickable counter in Pearl's
bar. You can then use the same approach for timers, images and animated companions.
You need basic programming and terminal knowledge; you do not need to write GTK
code or change Pearl itself.

Pearl's plugin API is experimental. This guide targets **`pearl:plugin@0.1.0`**.
For runtime setup and the full limits, see the [plugin reference](PLUGINS.md).

## How a plugin works

Pearl sends your plugin an **event**, such as “started” or “button clicked.” Your
plugin responds by publishing a **scene**: a list of labels, buttons and images.
Pearl draws those items as native widgets and sends future clicks back to you.

Your code runs in a separate helper process as a **WebAssembly component**. This
is a portable compiled file with a defined interface. The interface is written
in [WIT](../plugins/wit/plugin.wit), which describes the functions and data shared
between Pearl and a plugin. Generated bindings let your language use it.

The current interface supports bar widgets, timers, settings controls, PNG images,
sprite animations and desktop overlays. It does not expose files, networking,
commands, system services or arbitrary GTK/HTML interfaces to plugin code.
With a separate user grant and a supported Aqueous session, plugins can receive
coarse keyboard/mouse activity notifications. They never receive typed text or keys.

## Choose an example

These examples all use the same Pearl interface:

| Example | Language | What it teaches |
| --- | --- | --- |
| [Countdown](../plugins/examples/timer-c/plugin.c) | C | Labels, buttons, timers and a user setting |
| [Click counter](../plugins/examples/counter-zig/plugin.zig) | Zig | Calling generated C bindings from Zig |
| [Click counter](../plugins/examples/counter-rust/src/lib.rs) | Rust | Generated Rust bindings and a freestanding component |
| [Pearl Cat](../plugins/examples/companion-c/plugin.c) | C | Images, animation clips, Preview and overlay permissions |

Other languages need to produce a component implementing this WIT interface.
A compiler that produces an ordinary `.wasm` file is only part of that work.
C, Zig and Rust are the examples currently exercised by Pearl's tests.

## 1. Prepare your tools

Have a Pearl source checkout and a running Pearl build with plugins enabled.
The updated Arch PKGBUILDs enable the runtime and include the four examples.
For a manual Pearl build, follow [runtime build instructions](PLUGINS.md#build).

For this C tutorial, install or unpack:

- **Zig 0.16.0**, which provides the C compiler used below.
- [**wit-bindgen 0.62.0**](https://github.com/bytecodealliance/wit-bindgen/releases/tag/v0.62.0), which generates the interface bindings.
- [**wasm-tools 1.259.0**](https://github.com/bytecodealliance/wasm-tools/releases/tag/v1.259.0), which creates and validates components.

The runtime package does not install these development tools. You do not need
Rust or an image converter for this tutorial.

Run the commands below in Bash, from the **root of your Pearl checkout**, using
the same terminal throughout. Replace the two tool paths with your actual paths:

```sh
export WIT_BINDGEN=/absolute/path/to/wit-bindgen
export WASM_TOOLS=/absolute/path/to/wasm-tools
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"

zig version
"$WIT_BINDGEN" --version
"$WASM_TOOLS" --version

plugin_work="$PWD/.cache/plugin-tutorial"
mkdir -p "$plugin_work/source" "$plugin_work/bindings" "$plugin_work/package"
```

Check that the version output matches the versions above. The tutorial uses
`.cache/plugin-tutorial` as a scratch directory; keep your own plugin's source
in a separate project once you move beyond this exercise.

## 2. Describe your plugin

A plugin package is a folder containing a manifest and a compiled component:

```text
hello-c/
  plugin.json    Name, identity, version and optional settings/assets
  plugin.wasm    Compiled plugin code
```

Create the manifest:

```sh
cat > "$plugin_work/source/plugin.json" <<'JSON'
{
  "id": "example.hello-c",
  "name": "Hello counter",
  "version": "0.1.0",
  "interface": "pearl:plugin/guest@0.1.0",
  "component": "plugin.wasm"
}
JSON
```

`id` is the stable identity used for saved settings and bar placement. Give your
own plugin a unique ID, and keep it unchanged across updates. IDs can contain
letters, digits, dots, underscores and hyphens, must start with a letter or digit,
and are limited to 64 characters. `name` is the title shown in Settings.

`version` describes your plugin release. `interface` identifies the Pearl API
it implements. A basic bar widget needs no optional permissions.

## 3. Write the counter

Create the source file:

```sh
cat > "$plugin_work/source/hello.c" <<'C'
#include "plugin.h"
#include <stdio.h>

static unsigned clicks = 0;

// Turn a C abort into a Wasm trap; the guest has no process-exit API.
void abort(void) { __builtin_trap(); }

bool exports_pearl_plugin_guest_handle_event(
    exports_pearl_plugin_guest_event_t *event,
    plugin_string_t *err)
{
    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_DEACTIVATE)
        return true;

    if (event->kind == PEARL_PLUGIN_TYPES_EVENT_KIND_CLICK && event->node == 1)
        ++clicks;

    char label[64];
    snprintf(label, sizeof(label), "Clicks: %u", clicks);

    pearl_plugin_types_node_t button = {0};
    button.id = 1;
    button.kind = PEARL_PLUGIN_TYPES_NODE_KIND_BUTTON;
    plugin_string_set(&button.text, label);

    pearl_plugin_host_scene_t scene = {
        .nodes = {.ptr = &button, .len = 1}
    };
    return pearl_plugin_host_publish(&scene, err);
}
C
```

The long function name comes from the generated bindings; keep it as written.
Pearl calls it for each event. On activation it publishes `Clicks: 0`. A click
on node `1` increments the counter and publishes the updated button.

Node IDs identify interactive items, so every node in a scene needs a unique ID.
Each publication replaces the whole scene. Publish at most once per event and
return promptly. The local strings and node above remain valid through the
synchronous `publish` call; Pearl copies the scene for rendering.

The counter lives in plugin memory. It resets when the plugin restarts, including
after configuration changes or session suspension. There is no guest API for
saving arbitrary state to disk.

## 4. Compile a component

Run this block after each source change:

```sh
"$WIT_BINDGEN" c plugins/wit --world plugin --out-dir "$plugin_work/bindings"

zig cc -target wasm32-wasi -O2 -mexec-model=reactor \
  -I "$plugin_work/bindings" \
  "$plugin_work/source/hello.c" \
  "$plugin_work/bindings/plugin.c" \
  "$plugin_work/bindings/plugin_component_type.o" \
  -o "$plugin_work/hello.core.wasm"

"$WASM_TOOLS" component new "$plugin_work/hello.core.wasm" \
  -o "$plugin_work/package/plugin.wasm"
"$WASM_TOOLS" validate "$plugin_work/package/plugin.wasm"
cp "$plugin_work/source/plugin.json" "$plugin_work/package/plugin.json"
```

The first command generates the C bindings and interface metadata. The compiler
produces an intermediate core Wasm module; `component new` turns that into the
component Pearl loads. Ship `package/plugin.wasm`, not `hello.core.wasm`.

Successful validation normally prints nothing. It checks Wasm structure; loading
the plugin in Pearl also checks its interface, imports, manifest and scene.

## 5. Install and try it

Install the two package files into your user plugin directory:

```sh
plugin_install="${XDG_DATA_HOME:-$HOME/.local/share}/pearl/plugins/hello-c"
install -Dm644 "$plugin_work/package/plugin.json" "$plugin_install/plugin.json"
install -Dm644 "$plugin_work/package/plugin.wasm" "$plugin_install/plugin.wasm"
```

This path works for release and Git builds. Use regular files: Pearl rejects
symlinked package members.

Pearl discovers installed packages automatically. Open main **Settings → Plugins**
and select **Refresh plugins** if it has not appeared yet. No Pearl restart is needed. Then:

1. Open the main **Pearl Settings → Plugins** page.
2. Find **Hello counter** and select **Approve package**.
3. Turn on **Enabled** and select **Add to bar**.
4. Select **Apply & save**.
5. Click the new button in the bar. Its label should count upward.

Plugin management exists only in the main Settings application, not the flyout.
You can open the page with `pearl-settings --page plugins`; Git installations use
`pearl-settings-git --page plugins`. **Add to bar** updates the default right bar
group. If an output uses custom bar groups, add `plugin:example.hello-c/main` to
that output's group in **Bar & dock** as well.

Approval records a fingerprint of the manifest, component and declared images.
When any of those files change, rebuild and copy the updated files. Pearl stops
that plugin and displays its new fingerprint. Review its permission switches
(they default off for changed content), select **Approve package**, and Apply.
Unchanged plugins keep their counters, timers and helper processes.

For a clean update, build a complete package outside the plugin directory and
rename it into place. If replacing an existing directory, move the old directory
outside the discovery root first. Avoid keeping two versions with the same ID
under one root: Pearl reports a conflict instead of guessing which one to run.
Ordinary file copies also work; incomplete packages remain unavailable until valid.

**Refresh plugins** and `pearlctl plugins refresh` discover files. **Retry** and
`pearlctl plugins reload --path example.hello-c` restart an already discovered
instance. Removing a package stops it, while preserving its saved settings and
bar reference. Restoring exactly the approved files resumes an enabled plugin
when the session is unlocked. Plugin memory resets whenever its helper restarts.

## Add features a little at a time

### Settings controls

Declare settings in `plugin.json`; Pearl creates their controls in the plugin's
Settings card. For example, the countdown manifest contains:

```json
"settings": [
  {
    "key": "seconds",
    "label": "Starting seconds",
    "kind": "number",
    "default": "60",
    "min": 1,
    "max": 86400
  }
]
```

This is a field to add inside your manifest object. Supported kinds are `text`,
`number` and `toggle`. Defaults and event values are **strings**, including
numbers and the toggle values `"true"` and `"false"`.

Read the effective key/value pairs from the activation event's `settings` list.
Pearl fills in defaults and validates user values. Saving settings currently
restarts the plugin and sends a fresh activation event. Adding a manifest field
alone does not change your code's behavior; see the
[countdown handler](../plugins/examples/timer-c/plugin.c) for reading `seconds`.

### Timers

Call `set-timer(milliseconds)` to ask Pearl for a later `timer` event. In C that
function is `pearl_plugin_host_set_timer`. Check its result, just as the tutorial
checks `publish` by returning its result.

Timers are one-shot: schedule the next timer in your handler to keep ticking.
The allowed delay is 100 milliseconds to one day; `0` cancels the timer. Avoid
sleeping or looping inside the handler. The
[countdown example](../plugins/examples/timer-c/plugin.c) schedules one-second
ticks while running and cancels them when paused.

### Images and animated companions

Start with [Pearl Cat's manifest](../plugins/examples/companion-c/plugin.json)
and [event handler](../plugins/examples/companion-c/plugin.c):

1. Put PNG images in the package. Declare each image's ID, relative path, actual
   dimensions and license under `assets` in the manifest.
2. For animation, declare named `clips`. Each frame selects a rectangle from an
   asset and gives its duration in milliseconds.
3. Publish an `image` node referring to an asset or clip ID. Set its `text` to a
   useful description for accessibility.
4. Change the selected clip in response to a click or Preview event. Pearl draws
   the frames; your plugin does not need a timer for every animation frame.

PNG is the supported runtime image format. Pearl Cat's SVG is source artwork;
the example builder uses `rsvg-convert` to produce the packaged PNG. Honor the
event's `reduced-motion` flag by choosing a still pose. Pearl also stops clip
playback when reduced motion is enabled.

For desktop placement, add `"capabilities": {"overlay": true}` to the manifest.
After installing and approving the updated package, expand its settings, grant
**Allow desktop overlay**, choose **Desktop overlay**, configure placement and
apply. Enable **Accept clicks** if your overlay has buttons. Overlays hide during
lock/authentication and inactive sessions.

To make a Bongo Cat-style companion react to typing:

1. Declare `"capabilities": {"input_activity": true}` in `plugin.json`.
2. Call `pearl_plugin_host_input_activity(true)` from an event callback, usually
   activation. Check its returned availability before describing activity as live.
3. Handle `PEARL_PLUGIN_TYPES_EVENT_KIND_ACTIVITY` like Preview: publish a tap
   clip, alternating poses if desired. Respect `event->reduced_motion` with a
   still pose. The supplied cat already does this.
4. In main **Settings → Plugins**, approve and enable the package, switch on
   **Allow keyboard and mouse activity**, then **Apply & save**.
5. Launch Pearl through the matching Aqueous Pearl integration service; see
   [activity setup](AQUEOUS_PLUGIN_ACTIVITY.md). A manual launch cannot authorize
   itself merely by advertising the protocol.

Each activity event represents a coalesced notification; `count` is always `1`,
not the number of keys pressed. Notifications include fresh keyboard and mouse
button presses but exclude held-key repeats, motion, scrolling and virtual input.
Keyboard versus mouse categories stay inside Pearl. Bursts may merge or be
skipped, so use this for a playful reaction, never a keystroke counter.

`input-activity(false)` unsubscribes. The subscription change commits only when
your callback succeeds. Availability can be `available`, `permission-denied`,
`unsupported` or `suspended`; keep clicks and Preview useful in every state.
Pearl resets activity guests across privacy transitions, so do not rely on guest
memory surviving a lock or authentication prompt. This protocol cannot recognize
password fields inside ordinary applications.

## Use Zig or Rust instead

To build the existing C and Zig examples, install `rsvg-convert` for the cat
artwork and run this from the Pearl checkout:

```sh
python3 plugins/build-examples.py \
  --wit-bindgen "$WIT_BINDGEN" --wasm-tools "$WASM_TOOLS" --skip-rust
```

For the Rust example, also provision a Rust toolchain with the `wasm32-wasip2`
target. The compiler used for the initial tests was Rust 1.96.0. Prefetch its
locked dependencies, then run the builder without `--skip-rust`:

```sh
CARGO_HOME="$PWD/.cache/plugin-cargo" cargo fetch --locked \
  --target wasm32-wasip2 --manifest-path plugins/examples/counter-rust/Cargo.toml

python3 plugins/build-examples.py \
  --wit-bindgen "$WIT_BINDGEN" --wasm-tools "$WASM_TOOLS"
```

The builder compiles these named examples and writes their packages to
`.cache/plugin-examples/`. It does not install them or automatically discover new
source directories. Use it to learn the build commands, then adapt those commands
for your own project. Give a copied example your own manifest ID and name.

The Zig example imports the generated C header and links its bindings. The Rust
example uses `wit-bindgen` macros and `no_std`, with an allocator and explicit
`cabi_realloc` export. Keep those pieces when adapting it. An ordinary Rust WASI
application can import system APIs that Pearl does not provide and will fail to
load. The same restriction applies to imports from any other language.

## Troubleshooting

Inspect the plugin in Settings or run:

```sh
pearlctl plugins inspect --path example.hello-c
```

Use `pearlctl-git` on Git installations. The inspection includes status and an
error code. The guest `log` API currently discards messages, so do not rely on it
for console debugging.

| Symptom | What to check |
| --- | --- |
| Plugin is missing from Settings | Check the installation path, valid JSON, required files and regular-file permissions; select **Refresh plugins**. Invalid packages can be rejected during discovery. |
| `PluginRuntimeNotBuilt` | Run a Pearl build with `-Dwasm-plugins=true`, or rebuild/install the updated Arch package. |
| `PluginApprovalRequired` | Restart after replacing files, approve the new fingerprint, enable and apply. |
| Active but absent from the bar | Add its `plugin:<id>/main` reference to the active bar group and apply; check per-output overrides. |
| Failed during loading | Use the final component rather than core Wasm; check the WIT version and avoid WASI/system imports. |
| Failed after a click | Check unique node IDs, declared assets and host-call results; publish at most once and return promptly. |
| Suspended during lock or inactive session | This is expected. Pearl removes plugin views and restarts enabled instances when the session is available again. |
| Rebuild has no effect | Copy the new package files, select **Refresh plugins**, then review permissions and approve the changed package. Retry alone does not rescan. |

Keep scenes small: at most 32 nodes, including at most 4 images per scene.
Ordinary event handling has a 100 ms deadline plus a Wasm instruction budget.
For more limits and failure behavior, see the [reference](PLUGINS.md#limits-and-trust-boundary).

## Share your plugin

Distribute a folder containing `plugin.json`, the final component, declared PNGs
and the applicable licenses. Include a short README explaining what it does,
which Pearl API it targets, how to install it and any requested permissions.
Keep generated bindings, compiler intermediates and test fixtures out of the
installed package.

Before sharing, try installation into the user plugin directory, activation,
clicks, disabling and enabling, and a rebuild followed by renewed approval.
For companions, also try Preview, reduced motion and both bar and overlay
placement. Saved user settings should work after a plugin restart.

For host/SDK development, the existing [verification commands](PLUGINS.md#verification)
exercise all four examples and failure fixtures. The authoritative interface is
[plugin.wit](../plugins/wit/plugin.wit); manifest and scene validation live in
[model.zig](../src/plugins/model.zig).
