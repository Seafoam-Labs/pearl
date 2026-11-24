# Shell-drawn server-side decorations

Pearl can draw server-side window decorations (titlebars) for Aqueous instead
of the compositor's built-in borders. Pearl owns every pixel and their theming;
Aqueous keeps window policy (geometry, focus, workspaces, SSD negotiation,
input routing, transitions).

## Enable

The simplest control is the unified **Window decorations** dropdown in
Settings → Aqueous → Appearance → Window appearance. It derives from and
writes both underlying settings atomically:

| Selection | `decoration.renderer` | `layout.force_ssd` |
| --- | --- | --- |
| Off — applications draw their own | `compositor` | `false` |
| Compositor borders — all capable apps | `compositor` | `true` |
| Pearl titlebars — apps that request them | `shell` | `false` |
| Pearl titlebars — all capable apps | `shell` | `true` |

The two underlying fields remain editable in raw configuration; the dropdown
always reflects their current combination. The mapping is unit-tested
(`src/config/decoration_mode.zig`) and the full UI round-trip is covered by
`tests/integration/test_decoration_mode.py` (`zig build test-decoration-mode`).

For direct configuration, set the compositor fields in `wm.toml`:

```toml
[decoration]
renderer = "shell"   # "compositor" (default) keeps built-in borders
```

`layout.force_ssd` keeps its meaning: it forces SSD for all xdg-decoration
clients. With the shell renderer active, clients which *prefer* SSD are also
decorated without `force_ssd`. CSD-only clients are never forced. When Pearl
is not running, the compositor falls back to its own borders automatically.

## Contract

- Aqueous `aqueous_shell_manager_v1` **version 4** adds
  `get_window_decoration`, `window_interactive_move` and
  `window_interactive_resize`, plus the `aqueous_shell_decoration_v1` surface
  role (`destroy`, `set_offset`, `sync_next_commit`). See
  `Aqueous/compositor/protocol/aqueous-shell-v1.md`.
- Each window entity in the shell state carries `decoration` (xdg-decoration
  negotiation plus any rule `override`), `ssd_renderer` (`"shell"` when Pearl
  is expected to draw) and `operation` (`"none" | "move" | "resize"`).
  Pearl reconciles decorations against `ssd_renderer` on every coalesced
  sync; no Pearl-side preference is needed for enablement — the compositor
  configuration is the source of truth.
- Each decorated window owns two raw `wl_surface`s on GTK's borrowed display
  connection (`src/platform/wayland/decorations.zig`), double-buffered
  `wl_shm`, painted with Cairo + Pango from the live Material palette, desktop
  font and the compositor's `decoration.corner_radius`:
  - an **above-placement titlebar**: app icon (session icon cache), ellipsized
    title, minimize/maximize/close buttons with hover states (close uses the
    error palette);
  - a **below-placement frame**: soft shadow (disabled for maximized windows
    and under reduced motion) plus invisible resize grips. Its input region
    excludes the window content and the titlebar, so shadows never steal
    clicks. Grip presses send `window_interactive_resize`; cursor shapes come
    from `wp_cursor_shape_manager_v1`.
- Title drag sends `window_interactive_move` with the press serial;
  double-click toggles maximize; right-click opens the window menu
  (`src/desktop/window_menu.zig`, a layer-shell overlay at the pointer with
  minimize/maximize/fullscreen, move-to-workspace and close, all through the
  validated IPC command queue). Button actions route like the dock.
- During interactive moves/resizes (`operation != "none"`), geometry-driven
  redraws request `sync_next_commit` so new buffers land atomically with the
  compositor transaction; a 2 s watchdog falls back to unsynced commits.
- Fullscreen windows drop their decorations; minimized/invisible windows keep
  them (the compositor hides decorations with the window). Session lock and
  session-identity loss drop everything.
- **XWayland**: the compositor negotiates X11 decorations through
  `_MOTIF_WM_HINTS` (`aqueous/XwaylandDecoration.zig`): SSD strips the client's
  border/title and restores the original hints when SSD turns off. Clients
  which insist on their own decorations are honored even under `force_ssd`.
  XWayland titlebars render at scale 1 (native X11 scaling).
- **Per-window rules**: `[[rule]] decoration = "csd" | "ssd"` overrides the
  side per window (see `Aqueous/docs/rules.md`); editable in Pearl's window
  rule editor. CSD-only clients are never forced.

## Lifecycle and fallback

- Pearl disconnect/crash: the compositor destroys the shell decorations and
  restores built-in borders in one transaction; windows stay alive.
- Pearl restart: titlebars are recreated from the fresh shell snapshot.
- Compositor without v4 support: Pearl logs `shell-decorations-unavailable`
  and draws nothing; configuration remains valid.

## Validation

- Aqueous: `compositor/scripts/test-shell-decoration.sh` (headless protocol
  integration: state publication, creation, recoverable errors, owner-loss
  survival), `compositor/scripts/test-xwayland-decoration.sh` (MOTIF
  suppression, CSD honoring, restoration; requires `-Dxwayland` and Xwayland)
  and `zig build test` (`wm/decoration_policy.zig` matrix incl. X11 and rule
  overrides, rule config parsing).
- Pearl: `zig build test` (entity decode/clone of the additive fields,
  window-menu toggle policy, presentation coverage, binding reproducibility)
  and a private headless session smoke run (`scripts/dev-session.py` harness)
  verifying titlebar creation and owner-loss survival.
- Pointer-driven behavior (grips, cursor shapes, menu placement/dismissal,
  drag atomicity) needs a real pointer: validate in a nested session
  (`scripts/dev-session.py --backend nested`). Headless seats have no pointer
  capability.

## Remaining follow-ups

- Per-output shadow tuning and a dedicated shadows toggle (currently shadows
  follow reduced motion).
- Titlebar button layout customization (GNOME-style left/right buttons).
- Tablet/touch resize paths (pointer-only today).