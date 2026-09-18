# Aqueous input activity integration

Pearl integrates `aqueous-input-activity-v1` from Aqueous revision
`88587243059d58d72dd0fe2146d0ebdb64f26474`. With an authorized launch and a saved
input activity grant, Pearl Cat reacts to fresh keyboard and mouse-button presses
in other applications. [Validation results](PLUGIN_INPUT_ACTIVITY_VALIDATION.md)
distinguish isolated compositor tests from outstanding physical hardware checks.

## Enable live reactions

1. Use a Wasm-enabled Pearl build and an Aqueous build with this extension.
2. Install/select the matching **Aqueous Pearl integration** package and let its
   session service start Pearl. Keep its shell-selection conditions and drop-ins.
3. In **main Settings → Plugins**, approve Pearl Cat, enable it, grant **Allow
   keyboard and mouse activity**, then **Apply & save**. Desktop overlay access
   is a separate grant. Plugin controls are not in the flyout.
4. Check the source explanation and the plugin's Input activity status. The CLI
   also reports them through `pearlctl plugins list`.

Aqueous owns the launcher and integration units; Pearl does not install copies.
The reviewed layouts are:

| Aqueous channel | Owner unit | ExecStart |
| --- | --- | --- |
| Stable | `aqueous-pearl.service` | `/usr/bin/aqueous-activity-launch /usr/bin/pearl` |
| Git | `aqueous-git-pearl.service` | `/usr/lib/aqueous-git/bin/aqueous-activity-launch /usr/bin/pearl-git` |
| Intel Git layout | `aqueous-intel-git-pearl.service` | `/usr/lib/aqueous-intel-git/bin/aqueous-activity-launch /usr/bin/pearl-git` |

Current upstream Git packaging replaces older Intel Git integration packages;
match the compositor's installed instance, rather than assuming a CPU variant
implies a different service. Pearl Intel Git supplies the same `pearl-git` binary.
The integration preserves `KillMode=process` so a shell restart does not kill its
locker. Use Aqueous's shell selection rather than enabling a second shell unit.

Pearl's own `pearl.service`/`pearl-git.service`, direct commands and the reviewed
legacy upstream `install-welcome.sh` startup path do not obtain authorization.
Wrapping an unrelated unit in the launcher does not satisfy MainPID verification.
If Settings says **Launch not authorized**, use the matching integration package
and start a fresh session. Older Aqueous packages can satisfy Pearl's general
version floor while lacking this optional extension.

## Availability and privacy

| State | Meaning |
| --- | --- |
| `available` | The source is ready; delivery also requires this plugin's grant and subscription intent. |
| `permission-denied` | The plugin lacks a grant, or Pearl's launch authorization is missing/revoked. |
| `unsupported` | The protocol or native session source is absent. Production nested/headless sessions are unsupported. |
| `suspended` | Authorization/readiness is pending, the source is idle, or a privacy gate is closed. |

Clicks and explicit Preview remain available when global activity cannot run.
Reduced motion uses a still cat pose. Ordinary typing may be coalesced: the
protocol reports keyboard/mouse category presence at most once per 100 ms, with
no counts, keys, text, coordinates, input timestamps or device/application identity.
Guests receive the unchanged v0.1 activity event with `count=1`, meaning one
notification. Held-key repeats, releases, motion, scrolling and virtual input are
excluded. Pearl never opens raw input devices.

Pearl consumes the capability on GTK's existing Wayland connection, closes its
FD, removes its environment variable and prevents inheritance. It keeps one
subscription shared by eligible guests and removes it when no guest wants input.
Guest callbacks are rate limited, queues are bounded, and stale input is dropped.

Pearl stops local delivery before its authentication prompts and lock preparation,
then waits asynchronously for an acknowledged compositor inhibitor. If the ack
fails, it destroys the subscription and flushes within a 500 ms deadline before
continuing authentication. Resume requires fresh readiness; queued input and
activity poses cannot cross the privacy boundary. Compositor locks and inactive
native sessions also suspend delivery. **Password fields in ordinary applications
and browsers are outside this protocol's detectable authentication scope.**

See the [implementation plan](PLUGIN_INPUT_ACTIVITY_IMPLEMENTATION_PLAN.md) for
the pinned protocol contract and remaining hardware acceptance matrix.
