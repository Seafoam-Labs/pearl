# Logging and support diagnostics

Where Pearl logs go, how to make logs more verbose, what to check when a
subsystem fails, and how to hand a developer a bounded report.

## Where logs go

Pearl has no in-process log file. journald is the only production sink; the
sole diagnostic file Pearl writes is the `pearlctl report` bundle below.

| Context | Destination |
| --- | --- |
| Production session started by Pearl's own unit | `journalctl --user -u pearl.service` (`pearl-git.service` in the git packages), equivalently `journalctl --user -t pearl` |
| Production session started by Aqueous | Aqueous's integration unit, never Pearl's: `journalctl --user -u aqueous-git-pearl.service` ([unit layouts](AQUEOUS_PLUGIN_ACTIVITY.md#enable-live-reactions)). Those units set no `SyslogIdentifier`, so `-t pearl` matches nothing and the entries carry the launcher's identifier. |
| Any install, name unknown | `journalctl --user _EXE=/usr/bin/pearl` matches this executable's own lines wherever the unit naming leads; it does not include the unit's `systemd` start/stop messages or the applications the shell launched |
| Greeter / login (system unit) | `sudo journalctl -b -u pearl-greeter.service` |
| Session started by the greeter | also the system unit: the session inherits greetd's journal connection, so its stderr is attributed to `pearl-greeter.service` |
| Coral, Dome or Phyto started from the shell | the shell's own unit stream, told apart by `pid=` |
| Coral, Dome or Phyto started from a terminal | that terminal's stderr |
| Development sessions | one `.log` per process under the launcher output, default `.cache/dev-session/` (`scripts/dev-session.py`) |
| Integration suites | one `.log` per process under the suite's artifact output, e.g. `artifacts/t05/latest/surfaces/pearl.log` |

ReleaseSafe builds keep Zig's default panic and segfault handler, so crash
traces go to stderr and land in the same journal entries. A journald
"Suppressed N messages" note is itself a diagnostic signal: something flooded.

## Verbosity

All levels are compiled in and filtered at runtime, so no rebuild is needed:

- `pearl --log-level error|warning|info|debug` (Release builds default to `info`)
- `pearl --log-scopes aqueous,~gallery` (comma-separated scopes, `all` for
  every scope, `~scope` to exclude one)
- `pearlctl` accepts the same two flags on any command.
- `coral`, `dome` and `phyto` accept the same two flags.

Make it permanent with a systemd user drop-in (`systemctl --user edit
pearl.service`):

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/pearl --log-level debug
```

On an Aqueous-started shell the drop-in belongs to Aqueous's unit instead;
`pearlctl report` prints the query it used, which names it.

Limitation: the unit-launched executables (greeter, lock, settings, themes,
plugin host) take no flags and log at the build default; reaching them means
editing their units or the greetd config.

## Coral, Dome and Phyto

The three bundled applications share the shell's log handler, so their lines
carry the same `ts=<UTC> pid=<n> level(scope):` envelope and the same
`event=<name> key=value` payload convention. They have no log file and no
journal identity of their own. An application started from the dock or launcher
inherits the shell's stdout and stderr, so its lines land in the shell's unit
stream beside the shell's, told apart by `pid=`; `pearlctl report` therefore
already contains them. Started from a terminal, they log to that terminal
instead.

Scopes: `cli` for command-line problems, `config` for stored preferences
(Dome's and Coral's), `platform` for Phyto's preview pipeline and file
operations and for Coral's document I/O. What they log is deliberately small,
and none of it carries a path, a filename, document content or a provider
message:

- usage errors, on `cli`;
- `event=preferences-save-failed error=<cause>` when Dome or Coral cannot write
  its preferences, and `event=preferences-load-degraded outcome=<cause>` when
  Dome's stored file is unreadable, malformed, or a version this build does not
  understand. A missing file is the normal first run and is not logged;
- `event=preview-failed status=<reason>` from Phyto's preview pipeline;
- Coral document failures `event=document-load-failed`,
  `event=document-save-failed` and `event=file-chooser-failed`, each carrying
  only the `GError` `domain=` name and numeric `code=`. A dismissed dialog or
  aborted transfer arrives as `G_IO_ERROR_CANCELLED` and is dropped, so an
  abandoned chooser writes no error line;
- `event=operation-finished kind=<op> outcome=<ok|cancelled|conflict|partial|failed>
  completed=<n> skipped=<n> failed=<n>` from Phyto: one line per batch, never
  per item, so a large copy cannot flood the stream. The per-item reasons stay
  in the dialog, not the journal.

Phyto's preview converter is a sandboxed child whose stderr the supervisor
drains, so the converter's own lines never reach the journal in a production
build (instrumented builds echo them when a conversion fails). The visible
signal is Phyto's `event=preview-failed`: the first occurrence of each reason
at `warning`, repeats at `debug`, so a directory of unpreviewable files stays
one line.

## When something fails

`pearlctl` exits 0 on success, 2 on usage errors, 3 without a current Aqueous
session environment, and 4 when the shell answered with an error
([SURFACES.md](SURFACES.md)). Event names below are greppable journal keys.
Where a command says `pearl.service`, substitute the unit that started the shell
(the table above); `pearlctl report` resolves it and prints the command it used.

### The shell does not start / black screen

1. `pearl --check-environment`: works without a display; exit 2 prints the
   actionable environment problem, exit 1 is an application failure.
2. `journalctl --user -b -u pearl.service`: look for `event=startup-failed`
   and `event=session-error`.
3. `systemctl --user status pearl.service` shows the last exit status when the
   unit restart-loops.

### The greeter does not appear

1. `sudo journalctl -b -u pearl-greeter.service`; the launched session logs
   there too.
2. `coredumpctl info /usr/lib/pearl/pearl-greeter-host` for crashes.
3. A GNOME Keyring warning for the greeter account is not itself a fatal PAM
   failure; look for the process exit or crash that follows it.

### The lock does not engage

1. `pearlctl lifecycle status` reports capabilities and inhibitions.
2. `journalctl --user -b -u pearl.service | grep -E 'event=(lock-|lifecycle-failed|logind-session-unavailable)'`;
   `lock-output-limit` and `error=LockerMissing` name the degraded cases.

### A theme fails to load

1. `journalctl --user -b -u pearl.service | grep -E 'event=(css-error|resource-error|theme-command-failed|theme-index-offline)'`.
2. `pearlctl preferences status` reports the active and drafted appearance;
   the shell falls back to its bundled palette rather than failing.

### No audio

1. `pearlctl services status` reports per-service reasons, not booleans.
2. `pearlctl audio set ...` failures answer with a server error code;
   service-level problems appear under the `services` scope in the journal.

### The network applet is empty

1. `pearlctl connectivity status` reports the NetworkManager/BlueZ peer state.
2. `event=network-failed` / `event=bluetooth-failed` lines name the failed
   D-Bus call; NetworkManager must be running on the session bus.

### A compositor disconnect warning

`event=aqueous-disconnected` / `event=aqueous-availability` mean the shell lost
or regained the compositor IPC. The shell keeps its last known state and
reconnects; check the compositor's own journal for the crash or restart that
caused it, and `event=ipc-*` lines for the protocol-level detail.

### A file preview is missing

1. `journalctl --user -b -t pearl | grep event=preview-failed`: the `status=`
   value names the reason.
2. `missing_pdf` needs Poppler (`pdftoppm`), `missing_video` needs FFmpeg
   (`ffmpeg` and `ffprobe`), `sandbox` needs bubblewrap. `limits`, `timeout`,
   `unsupported` and `changed` describe the file, not a missing dependency.
3. Phyto shows the same sentence as the preview caption, so the reason is
   visible without the journal.

## Reporting a bug

1. While the shell is running, execute `pearlctl report`.
2. Attach the file named in the reply's `path`
   (`~/.local/state/pearl/report-<UTC timestamp>.log`) to a
   [GitHub issue](https://github.com/Seafoam-Labs/pearl/issues), together with
   a description of what you did and what happened.

A report is one bounded text file: the shell's launch argv, version and the
effective `log-level`/`log-scopes` filter (so a reader knows whether the debug
lines they want were even emitted by that run), `pearl --check-environment`
output, the live `pearlctl status` JSON, and the last 500 lines of the shell's
own journal stream. The status section is capped at the same 8192-byte frame a
plain `pearlctl status` reply must satisfy; a probe that fails or exceeds it
degrades to `{"unavailable":true,"error":"<name>"}` instead of dropping the
section, and the same Zig error name is logged as
`event=report-status-unavailable error=<name>`. The section header is the exact
`journalctl --user` query used: the unit read from the shell's own cgroup, or
`_EXE=<its executable>` when the unit query does not answer (a terminal, a login
scope, or a unit stream that matched nothing). A stream that yields
nothing says `journal=no-entries` under the query that was tried, and one that
could not be read says `journal=unavailable reason=…`; a missing source never
fails the report, and the system journal is never read, so a greeter-launched
session's lines are not included. The directory is `0700`, files are `0600`, and
the last 3 reports are kept.

Never in a report or the journal: typed content, passwords, passphrases,
clipboard payloads or session tokens. Untrusted strings (compositor messages,
theme errors, peer ids) are sanitized before logging: control bytes replaced,
a 512-byte cap, URL credentials redacted, and session tokens appear only as
irreversible fingerprints (`session_hash=` in log lines, the fingerprinted
`session` field in the report's status section). `event=report-written` records
only the report's `name=`, not its full state path: the path exposes home and
deployment details to a stream other tools read, and the IPC reply already
returns it to the requesting terminal.

## For developers

Every line carries a `ts=<UTC> pid=<n>` envelope ahead of the standard
`level(scope):` prefix, and payload lines use the `event=<name> key=value`
convention. Every event name is declared in `src/core/log_events.zig`, and a
pure test walks the shell's and the three subprojects' sources and fails on
undeclared or stale names, or on an event whose declared scopes do not include a
scope the emitting file actually binds with `std.log.scoped`; runtime
level/scope filtering lives in `src/core/logging.zig`. Coral, Dome and Phyto
wire both files as build modules by relative path rather than copying them, so
one handler serves every executable in the tree.

Level choice: `info` carries what a support report needs without asking the
user to raise verbosity — lifecycle transitions, capability changes, failures,
and a popup the shell closed on its own (`event=popup-close-reason` for reasons
such as `bar-inhibited` or `output-removed`). Traces of ordinary interaction,
such as opening or dismissing a popup and per-keystroke search timings, are
`debug`: at `info` they dominate the journal and bury the lines that explain a
failure. A driver that asserts on a debug line must run its child with
`--log-level debug` and a scope list narrow enough to stay under the harness
`log_limit`, past which captured lines are silently dropped.
