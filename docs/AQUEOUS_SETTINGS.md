# Aqueous settings in Pearl

Open **Control center → Aqueous settings**, or run `pearlctl aqueous show`.
This replaces the existing settings application's frontend. Pearl does not launch
that application. The standalone `aqueous-config` helper remains the canonical
TOML backend; install that helper alongside Pearl. Shell appearance, including
system/installed GTK themes, remains under **Pearl settings**.

Pearl discovers `aqueous-config` through PATH, checks protocol 1 and the required
capabilities, and always passes `--shell none`. The tested helper is 0.7.2. Neither
`--shell pearl` nor a DMS/Noctalia appearance adapter is used.

## Editing and outcomes

Appearance, Layouts, Input, Keybindings, Rules and Displays are generated from the
helper's current fields. All 221 fields in the tested schema have controls; the
[field inventory](AQUEOUS_FIELD_INVENTORY.md) records their coverage. Descriptions,
select choices, numeric limits, colors and default values come from the helper.
Advanced exposes the six raw TOML files and the complete helper request JSON.
Unknown TOML settings and comments are left to the canonical backend.

Drafts belong to the service and survive closing/reopening the view. Invalid JSON
and invalid values remain editable. Raw edits are retained as you type; a raw
file and structured changes to that same file conflict and cannot be applied.
Remove one representation in Advanced to resolve that conflict. Drafts currently
survive view destruction, not a whole Pearl process restart.

**Validate** prepares a candidate without writing and without advancing the
draft's `expected_generation`. **Apply & save** validates again and sends that
original generation. Refresh reads current files without discarding the draft.
**Rebase draft** merges independent structured fields; conflicting fields,
changed raw files and changed index-based collections require manual resolution.
Refreshing/rebasing is explicit, so a newer version cannot silently replace the
base of an older edit. A draft edited while an operation runs remains retained.

The status reports these independently:

- **Canonical save:** saved, failed, or uncertain. A failed/lost apply response
  triggers a snapshot comparison with the validated candidate and original files.
  It never triggers an automatic retry. A read-back proving the candidate was
  saved still retains the draft and reports reload/toolkit completion as unknown.
- **Reload:** the helper performs `session.reload` itself. Pearl gates apply on
  the Aqueous `config_reload` capability and reads `--report-reload true` stderr;
  only the helper's confirmed `applied` result counts. A failed reload does not
  turn an already saved configuration into a failed save. Retry compositor reload
  (or `pearlctl aqueous reload`) retries only that action. A file-watch event is
  never treated as acknowledgement.
- **Toolkit synchronization:** not requested, synced, partial or unknown. The
  Appearance page includes the individual font/cursor target reports. Partial
  synchronization never undoes a successful canonical save.

After an uncertain save, Refresh and review the current configuration before
rebasing. Apply remains blocked until that explicit review succeeds. Discarding
a draft alone does not authorize another uncertain write.

System configuration requires an explicit `"create_user_override": true` in the
draft. Multi-file backups are written by the helper below
`$XDG_STATE_HOME/pearl/aqueous-backups/<original-generation>/`. Advanced cannot
redirect that backup directory.

## Shortcut recording

Record a binding on the Keybindings page. Pearl waits for GDK's
`shortcuts-inhibited` acknowledgement before accepting a chord. Escape, page
changes, loss of inhibition, compositor unavailability, closing the view and the
30-second deadline restore shortcuts. Modifier-only presses are ignored.
The integration test checks a real Aqueous `spawn:` marker binding: it must not
run while recording, and must run again after the popup closes.

This uses Ghostty's generated GTK/GDK bindings, including
[`GdkToplevel` shortcut inhibition](https://docs.gtk.org/gdk4/method.Toplevel.inhibit_system_shortcuts.html).

## Protected display preview

Connected, enabled displays support position, scale, rotation and advertised
modes. **Apply & save** starts an independent `pearl --display-guard` process.
The internal entrypoint uses anonymous descriptors; it is not a command intended
for interactive use. The guardian owns its own Wayland connection and original
display state. No canonical configuration is written before **Keep displays**.

The guardian tests the candidate, applies it with the compositor's configuration
serial, and starts a 15-second lease. Revert, timeout, parent pipe closure after
Pearl crashes, or a changed output configuration triggers rollback. Only heads
still exactly matching the candidate are restored; other heads keep their current
state. A newly racing configuration cancels the serial-based rollback instead of
overwriting that configuration. Hotplug invalidates the lease. A dead compositor
has no surviving display state to restore; failures remain explicit.

Keep revalidates the original helper generation, checks the live configuration
again, then saves through the helper and reports its reload result. A competing
canonical edit cannot silently overwrite that generation. The guardian uses
generated `zwlr_output_manager_v1` v4 bindings, not shell commands or a C bridge.

Explicitly gated cases:

- Mirroring has no representation in this output-management protocol. Mirror
  changes remain available for inspection/raw drafting and validation, but are
  not applied through an unprotected path.
- Raw outputs changes are always gated, including properties omitted from the
  helper snapshot. Raw wm edits are also gated when either version contains
  legacy output/display sections; raw wm without such sections remains editable.
- Custom/unadvertised modes, enabling disabled displays, offline outputs and raw
  output-policy changes cannot use this preview. The five display policy fields
  can be drafted/validated; changing them at apply is gated. The helper's
  compatibility `rollback_seconds` setting is **not** a crash-safe lease.
- Visual drag-and-drop display placement, window-rule builders and snap-layout
  canvases are deferred. Current collection editing uses the helper request JSON
  below; it does not hand off to the old application.

## Collection request examples

Use the generation displayed by `pearlctl aqueous status`. Begin with:

```json
{
  "protocol": 1,
  "expected_generation": "COPY_CURRENT_GENERATION",
  "changes": [],
  "raw_files": {}
}
```

Add the relevant request member. IDs for existing records come from the
expandable inventories on each page and must stay attached to that generation.

| Editor | Request member and example |
| --- | --- |
| Custom keybindings | `"custom_keybind_changes": [{"op":"add","chord":"Super+E","command":"spawn:nemo"}]` |
| Update/delete custom binding | `{"op":"update","id":"custom:INDEX","chord":"Super+E","command":"spawn:nemo"}` or `{"op":"delete","id":"custom:INDEX"}` |
| Window rule | `"window_rule_changes": [{"op":"add","values":{"app_id":"example","floating":true}}]` (the helper validates supported keys) |
| Update/delete/reorder rule | `{"op":"update","id":"rule:INDEX","values":{...}}`, `{"op":"delete","id":"rule:INDEX"}`, or a separate `{"op":"move","id":"rule:INDEX","direction":1}` operation |
| Snap layouts | `"snap_layouts": [{"id":"halves","zones":[{"id":"left","x":0,"y":0,"width":0.5,"height":1}]}], "default_snap_layout":"halves"` |
| Legacy snap zone | `"snap_zone_changes": [{"id":"ID_FROM_SNAPSHOT","x":0,"y":0,"width":0.5,"height":1}]` |
| Display | `"monitor_changes": [{"id":"live:DP-1","name":"DP-1","x":0,"y":0,"scale":1.25,"transform":"normal"}]` |
| Font/cursor synchronization | `"sync_typography": true` / `"sync_cursor": true` |
| Normalize stacking aliases | `"normalize_stacking": true` |

## CLI and verification

```sh
pearlctl aqueous show
pearlctl aqueous show --text displays
pearlctl aqueous status
pearlctl aqueous status --text layout.gaps_outer
pearlctl aqueous status --text monitors
pearlctl aqueous status --text raw:layout
pearlctl aqueous draft --text '{"protocol":1,"expected_generation":"...","changes":[{"id":"layout.gaps_outer","value":16}]}'
pearlctl aqueous validate
pearlctl aqueous apply
pearlctl aqueous keep       # only during a pending preview
pearlctl aqueous revert
pearlctl aqueous refresh
pearlctl aqueous reload
pearlctl aqueous rebase
pearlctl aqueous discard
```

The CLI retains its 8 KiB frame bound (draft text up to 6,500 bytes). Larger
requests use GTK Advanced, with a 4 MiB UTF-8 bound and depth limit 32. Helper
stdout is capped at 16 MiB and stderr at 64 KiB, drained together. Each helper
invocation has a 35-second deadline and its own process group, killed and reaped
on cancellation. The independent guardian has a separate 150-second overall
parent deadline and 3-second Wayland operation deadlines; the confirmation lease
itself is always 15 seconds. All work runs outside the GTK event thread.

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-aqueous-settings -Doptimize=ReleaseSafe
```

Tests use private buses, temporary HOME/configuration, synthetic keyboard input
and headless outputs. Physical monitor mode/rotation/mirroring behavior remains a
hardware validation task; virtual-output tests do not claim that coverage.
