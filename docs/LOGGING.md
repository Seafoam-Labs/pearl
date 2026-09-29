# Logging and support diagnostics

Where Pearl logs go, how to make logs more verbose, what to check when a
subsystem fails, and how to hand a developer a bounded report.

## Where logs go

Pearl has no in-process log file. journald is the only production sink; the
sole diagnostic file Pearl writes is the `pearlctl report` bundle below.

| Context | Destination |
| --- | --- |
| Production session (user unit) | `journalctl --user -u pearl.service` (equivalently `journalctl --user -t pearl`) |
| Greeter / login (system unit) | `sudo journalctl -b -u pearl-greeter.service` |
| Session started by the greeter | also the system unit: the session inherits greetd's journal connection, so its stderr is attributed to `pearl-greeter.service` |
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

Make it permanent with a systemd user drop-in (`systemctl --user edit
pearl.service`):

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/pearl --log-level debug
```

Limitation: the unit-launched executables (greeter, lock, settings, themes,
plugin host) take no flags and log at the build default; reaching them means
editing their units or the greetd config.

## When something fails

`pearlctl` exits 0 on success, 2 on usage errors, 3 without a current Aqueous
session environment, and 4 when the shell answered with an error
([SURFACES.md](SURFACES.md)). Event names below are greppable journal keys.

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

## Reporting a bug

1. While the shell is running, execute `pearlctl report`.
2. Attach the file named in the reply's `path`
   (`~/.local/state/pearl/report-<UTC timestamp>.log`) to a
   [GitHub issue](https://github.com/Seafoam-Labs/pearl/issues), together with
   a description of what you did and what happened.

A report is one bounded text file: the shell's launch argv and version,
`pearl --check-environment` output, the live `pearlctl status` JSON, and the
last 500 lines of `journalctl --user -u pearl.service` (or
`journal=unavailable` when the user journal cannot be read; a missing source
never fails the report, and the system journal is never read). The directory
is `0700`, files are `0600`, and the last 3 reports are kept.

Never in a report or the journal: typed content, passwords, passphrases,
clipboard payloads or session tokens. Untrusted strings (compositor messages,
theme errors, peer ids) are sanitized before logging: control bytes replaced,
a 512-byte cap, URL credentials redacted, and session tokens appear only as
irreversible fingerprints (`session_hash=` in log lines, the fingerprinted
`session` field in the report's status section).

## For developers

Every line carries a `ts=<UTC> pid=<n>` envelope ahead of the standard
`level(scope):` prefix, and payload lines use the `event=<name> key=value`
convention. Every event name is declared in `src/core/log_events.zig`, and a
pure test fails on undeclared or stale names; runtime level/scope filtering
lives in `src/core/logging.zig`.
