# Startup applications (XDG autostart)

Pearl manages login startup applications through the standard XDG autostart
directories, so entries configured in Pearl are honored by other sessions
(GNOME, KDE, …) and entries created elsewhere show up in Pearl.

## Storage

- User entries: `$XDG_CONFIG_HOME/autostart/*.desktop` (usually
  `~/.config/autostart`).
- System entries: `/etc/xdg/autostart/*.desktop`.
- A user file with the same base name **masks** the system entry, matching
  the XDG autostart specification.

Entries Pearl adds through Settings are ordinary desktop files carrying two
extra keys:

```ini
X-Pearl-Managed=true
X-Pearl-Source-Id=<installed desktop id>
```

## Lifecycle semantics

| Action          | User entry                          | System entry                              |
| --------------- | ----------------------------------- | ----------------------------------------- |
| Add             | write `<app-id>.desktop`            | —                                         |
| Disable         | rewrite the file with `Hidden=true` | copy it to the user directory with `Hidden=true` (mask) |
| Enable          | remove `Hidden` and the legacy `X-GNOME-Autostart-enabled` key | remove/replace the user mask |
| Remove          | delete the file                     | mask with `Hidden=true` (system files are never modified) |

Removing a user file that masked a system entry lets the system entry
reappear, the same way gnome-session behaves.

## Launch selection

The shell launches each entry once per session, after the Aqueous session is
verified and unlocked (see `Manager.sync` in `src/ui/surfaces/manager.zig`).
An entry is launched when all of the following hold:

- `Hidden=true` is absent (and the legacy `X-GNOME-Autostart-enabled` is not `false`),
- `OnlyShowIn` (when present) matches one of the `XDG_CURRENT_DESKTOP` values,
- `NotShowIn` matches none of them,
- `TryExec` (when present) resolves to an executable,
- the file parses as a `Type=Application` desktop entry with `Name` and `Exec`.

`X-GNOME-Autostart-Delay=<seconds>` postpones the launch (capped at one
hour). Launches use `GDesktopAppInfo` with the session's GDK launch context
and are logged as `event=autostart-launched` / `event=autostart-launch-failed`.

## Components

- `src/services/autostart_policy.zig` — pure parsing, launch selection,
  `Hidden` toggling and file rendering (unit-tested via `zig build test`).
- `src/services/autostart.zig` — directory scan, `GFileMonitor` watches,
  add/enable/disable/remove mutations (atomic temp-file writes) and the
  session launch run. Test hooks: `PEARL_TEST_AUTOSTART_USER` and
  `PEARL_TEST_AUTOSTART_SYSTEM` override the scanned directories.
- Shell: `src/ui/surfaces/manager.zig` owns one instance and triggers the
  one-shot launch.
- Settings: the dedicated "Startup applications" page (route id `startup`,
  next to System in the sidebar) owns its own service instance, following
  the scheduler-service precedent; `src/settings/autostart_view.zig` renders
  the list, the enable switch, removal and the application picker.

Both instances watch the directories, so edits made outside Pearl (another
DE's tool, a file manager) appear without a restart.
