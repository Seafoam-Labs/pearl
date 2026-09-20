# Dock and islands (T15)

T15 uses **detached bar islands**, replacing the planned connected desktop frame.
The default bar has separate rounded start, center and end sections. Set
`bar.islands=false` for a continuous floating bar. Both modes use one GTK window
and one measured reservation on the selected edge. There are no additional
island reservations. The old `frame set` CLI remains available for compatibility;
it is not part of the island layout or settings UI.

The bar's input and native Aqueous blur regions are the union of its populated
rounded sections. Empty sections, rounded corners and gaps accept no input and
receive no blur. Layout changes update that union from actual GTK allocations.
The dock uses the same native background-effect integration and rounded input
region. GTK themes retain their own colors; Material themes supply Pearl colors.

Left/right bars retain the configured thickness. Icons and status values stack,
the clock stacks weekday, day and month above separate hour/minute lines, and
workspaces stay in one column. Horizontal clocks include the day and month inline.
Overflow scrolls vertically instead of creating more columns. Returning to a
top/bottom edge restores horizontal widgets and full keyboard-layout labels.
`zig build test-bar-layout -Drelease=true -Doptimize=ReleaseSafe` checks actual GTK
allocations across edges, themes, text sizes and mixed-scale output changes.

## Global bar task widget

The optional `running_apps` bar widget uses the same application matching as
the dock with a global window source. It includes every workspace and display,
has no pins, and opens a window chooser for multi-window applications. The dock
continues to filter by output and cycle windows on primary click. Configuring
one does not configure the other. See [DESKTOP.md](DESKTOP.md#running-applications-in-the-bar).

## Dock behavior

Each output has its own running application groups and the same ordered list of
pins. Windows belong to their authoritative Aqueous output. `skip_taskbar`
excludes a window; `skip_switcher` does not. Minimized windows and windows on
inactive workspaces remain available. A unique desktop-ID or StartupWMClass
match associates running windows with installed applications. Ambiguous matches
remain separate running groups. No command line is guessed from a window title.

Click an icon to activate its window or cycle through the group's windows. An
installed pin with no windows launches through GIO. Right-click the icon to open
its action menu, which provides new-window launch, desktop actions, pin/unpin, and per-window activate,
minimize/restore, maximize/restore and close. Actions retain copied opaque IDs
and validate against current Aqueous state or the current GIO desktop entry.
Unavailable or removed pinned applications can still be unpinned.

### Custom application launchers

When a custom `.desktop` file has a different filename from the packaged entry,
its window may still identify itself as the packaged application. Open the
running application's dock menu, choose **Use launcher…**, search for the custom
entry, and select **Use launcher**. Pearl remembers that choice for windows with
the same Wayland app ID or XWayland class. The dock and Running applications bar
widget then use the selected entry's icon and name. Pinning and **Open new
window** use its launch arguments and desktop actions.

Changing an already pinned group also replaces that pin in the same save. If
the chosen entry is already pinned, Pearl retains its existing position and
removes the replaced source pin. Choosing a launcher for an unpinned group does
not pin it automatically.

Use **Reset to automatic** in the picker, or remove the choice under
**Settings → Bar & dock → Application launchers**, to restore automatic matching.
Reset preserves saved pins. Settings removals use the normal Apply/Discard draft
workflow. Missing or hidden selected launchers remain unavailable until restored
or changed; Pearl never silently launches the packaged entry instead.

The choice applies to every window reporting that application identity,
including profiles that share it. Automatic detection of the original custom
launcher is not implemented. A user override with the **same desktop-file ID**
already follows GIO's XDG precedence and requires no extra choice.

See [implementation and verification](DOCK_DESKTOP_OVERRIDES_IMPLEMENTATION_PLAN.md)
and [native acceptance evidence](../artifacts/dock-desktop-overrides/README.md).

Dots indicate running windows; a filled dot and highlighted button indicate
focus. Accessible button labels and tooltips include the application name,
running count, focus, minimized state and pin status. Native GTK buttons
and popovers supply roles and standard keyboard interaction.

The dock supports these visibility modes:

- `always`: visible except while locked, empty, disabled or covered by fullscreen.
- `intelligent` (default): also hides when a visible, non-minimized window's
  global logical `outer_geometry` overlaps the dock. Hidden-workspace windows
  do not obstruct it. Even taskbar-excluded windows can obstruct it.
- `autohide`: hidden until pointer or keyboard interaction.

A centered two-logical-pixel strip at the chosen edge reveals the dock. It remains
mapped during interaction, and crossing the margin has a 450 ms grace period.
The reveal strip occupies only the dock's bounded length, with no reservation.
Aqueous places fullscreen windows above top-layer surfaces, so the reveal strip
uses the overlay layer; a revealed dock rises above fullscreen until dismissed.
Lock requests, locked/inactive known sessions, sleep preparation and authentication
prompts hide the dock and release keyboard input. Output removal, IPC loss or
native-display identity mismatch destroys the affected surfaces.

The dock floats without reserving desktop space. If its configured edge matches
the bar edge it moves to the opposite edge. Placement uses logical coordinates,
including negative origins, and GTK handles output scale. Large application
lists scroll along the edge; there is no magnification or animation loop.
Limits are 16 global pins, 32 groups per output, 64 windows per group and eight
desktop actions per menu. `status` reports group truncation.

## Settings and commands

Open **Pearl settings → Bar & behavior** to select islands, dock visibility,
edge, icon size (24–64 logical pixels) and margin (4–32). Advanced JSON supports
per-connector dock overrides. A missing/null output dock inherits the global
dock. Pinning persists through the existing revision-checked preference service.

```json
{
  "bar": {"islands": true},
  "dock": {"enabled": true, "edge": "bottom", "mode": "intelligent", "icon_size": 40, "margin": 8},
  "pinned_apps": ["org.example.Editor.desktop"],
  "outputs": [{"connector": "DP-1", "dock": {"edge": "right", "mode": "autohide"}}]
}
```

This is a partial configuration example; the normal preference parser supplies
missing defaults. An output's `bar` follows the existing full-override semantics.
A connector entry with no `bar` therefore uses the default bar configuration.

```sh
pearlctl dock show --output OUTPUT_ID
pearlctl dock hide --output OUTPUT_ID
pearlctl dock pin --text org.example.Editor.desktop
pearlctl dock unpin --text org.example.Editor.desktop
pearlctl status
```

`dock show` gives the first icon keyboard focus. Use Tab/Shift-Tab or arrow keys,
Space/Enter to activate controls, Menu or Shift+F10 to open the focused icon's
action menu, and Escape to dismiss menus and release the
dock's keyboard mode. `dock hide` ends forced interaction; an unobscured `always`
or `intelligent` dock can remain visible. Bind `pearlctl dock show` using the
Aqueous settings application's keybinding editor.

`status.outputs[]` includes `islands`, window-local `island_rects`, and a `dock`
record with visibility reason, group count, truncation, effective edge and global
logical bounds. These report actual state, not a second window database.

See [T15 evidence](../artifacts/t15/README.md) for validation and visual coverage.
Hardware presentation, assistive-technology speech and physical multi-monitor
acceptance remain release gates; a screenshot alone does not certify them.
