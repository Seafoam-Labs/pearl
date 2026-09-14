# Moving from DMS to Pearl

Pearl imports a conservative subset of Dank Material Shell appearance, bar and
dock preferences. It never changes DMS configuration, enables a service, or
switches the running desktop. Keep DMS installed: current Aqueous packages depend
on `dms-shell`; Pearl does not pretend to provide that package.

## Prepare and review offline

Use a copy of your DMS settings and, optionally, session file. The importer accepts
the inspected DMS settings format 18/session format 4 (reference revision
`72ca8a6876b014f5722a00f69301a5766653764e`). Missing version fields are allowed;
a different explicit version is rejected. Each input must be a regular file,
maximum 64 KiB; symlinks and FIFOs are rejected.

```sh
pearlctl migrate dms --input /path/to/settings.json \
  --session-file /path/to/session.json --base /path/to/pearl-preferences.json
```

This prints a JSON dry-run report with the full candidate, mapped and unsupported
field paths, notes and source hashes. It works without a running compositor.
`--base` preserves unrelated Pearl preferences, including islands, per-output
policies, idle settings and exports. Omit it for Pearl defaults. `--session-file`
is optional. Unsupported fields are preserved in the original DMS file and are
not applied to Pearl.

| DMS fields | Pearl mapping |
| --- | --- |
| `fontFamily`, `fontScale`, `reduceMotion` | Font, rounded `14 × scale` font size (10–24), reduced motion |
| `showDock`, `dockAutoHide`, `dockPosition`, `dockIconSize` | Enabled, autohide/always, edge, size (24–64) |
| First enabled `barConfigs` entry targeting `all` outputs | Edge and ordered left/center/right widget groups |
| Session `isLightMode` | Light/dark variant; existing theme mode remains |
| Session `wallpaperPath` | Hex solid color or absolute image path in cover mode |
| Session `pinnedApps` | Up to 16 validated desktop IDs, `.desktop` suffix normalized |

DMS positions map explicitly: 0 top, 1 bottom, 2 left, 3 right. Centered dock
positions are rejected. Recognized widgets are launcherButton, workspaceSwitcher,
focusedWindow, music, clock, systemTray, clipboard, notificationButton, battery and
controlCenterButton. Duplicates are reported, and a missing launcher is added.
Other bars, per-monitor DMS layouts, custom widgets/plugins, exact spacing,
transparency, theme algorithms and frame settings require manual choices in
Pearl. The importer does not reproduce arbitrary DMS scripts or integrations.
Pearl's GTK theme mode remains available independently of migration.

## Create a backup bundle

Repeat the reviewed command with `--bundle /path/to/new-private-directory`.
The directory must not exist. It is created with mode 0700; its files use 0600:

- `previous.json`: exact base bytes, or `{}` when defaults were selected.
- `preferences.json`: validated candidate.
- `report.json`: review report, written last to mark a complete bundle.

A partial failure may leave a private incomplete directory. Inspect it and use a
new directory for another attempt. DMS inputs and the live Pearl configuration
remain untouched. Store the original DMS files separately for your own backup.

## Apply in a Pearl test session and restore

Start Pearl in a private Aqueous session using [DEVELOPMENT.md](DEVELOPMENT.md).
From a terminal with that session's environment, inspect
`pearlctl preferences status` and use its current `result.revision`:

```sh
pearlctl preferences apply --revision CURRENT_REVISION --file /path/to/bundle/preferences.json
pearlctl preferences status
```

The apply request is asynchronous: check that `busy` is false and `err` is null.
A successful command acknowledgement alone does not prove the theme/image loaded.
Stale revisions fail with a conflict and cannot overwrite newer preferences.
`--file` reads and validates locally, then uses the existing bounded control API;
JSON requests must fit its 8 KiB frame. Larger existing configurations remain
supported on disk through the preferences workflow; migration does not expand the
control transport or silently truncate them.

To restore, read the new revision and apply `bundle/previous.json` the same way.
That restores the saved preference values; it does not restore a former file's
absence or reset the revision counter. DMS itself needs no preference rollback,
since its files were never changed.

## Choose a shell for the next login

Before changing startup, save the active user startup file and record which DMS
unit is enabled (`dms.service` or `aqueous-dms.service`, depending on packaging).
Choose either direct startup or the Pearl user service described in
[RELEASE.md](RELEASE.md). Disable only the recorded previous shell's next-login
startup and add Pearl to that same session path. Do not run two shell services
that compete for notification, tray or layer-surface ownership.

Log out and back in to test the switch, retaining another way to edit your user
configuration. To switch back, disable Pearl's next-login startup, restore your
saved startup file and the previously recorded DMS enablement, then log in again.
Package installation and the importer never execute these steps for you. Do not
stop an active `pearl-lock` helper merely to switch shells; unlock normally first.
