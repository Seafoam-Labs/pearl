# CPU scheduler profiles

CPU scheduler profiles let people choose how the system schedules work, such
as Default, Cosmos or LAVD, without picking sched_ext schedulers and options
themselves. The profiles are scx's: Pearl shows the
[scx scheduler catalog](https://github.com/sched-ext/scx/blob/main/services/CATALOG.md)
and changes the scheduler only through `scxcli`, the tool scx ships for that.
The same profiles, and the same selection, show in `scxcli` and scxtui.

Profiles are offered by the `scheduler` bar widget (**Settings -> Bar & dock ->
Add widget -> CPU Scheduler**). It shows the active profile, and clicking it
opens a flyout with the profiles and their descriptions. The widget appears
only when `scxcli` is installed, the kernel supports sched_ext and
`scx.service` is installed.

## Requirements

Profiles need scx with `scxcli` (sched-ext/scx after 1.1.4):
`/usr/bin/scxcli`, `/usr/share/scx/catalog.json`, `scx.service` and scxcli's
polkit policy, `org.sched_ext.scxcli.policy`.

Pearl ships no polkit policy for this any more. Its own one,
`org.aqueous.Pearl.Scheduling`, authorized `pearl-scheduling-helper`, which
is gone: every privileged step is now `pkexec /usr/bin/scxcli …`, and that
is what scx's policy covers (installed by scx's `cargo xtask install` and by
distribution packages of scx). Without it, pkexec falls back to its generic
action and asks for an administrator password at every step, choosing a
profile included.

Two versions are involved and they are separate contracts:

- scxcli's JSON output (`list --json`, `get --json`) must be version 2;
  Pearl says so when an scxcli prints another one.
- The catalog file may be version 1 or 2, as scx accepts both. Pearl writes
  version 2 only when the profiles it saves include custom ones (a version 2
  key), and then writes out the featured list a version 1 file derived, so
  the file stays valid; otherwise the version is kept.

## The catalog

scx ships `/usr/share/scx/catalog.json`; an administrator's
`/etc/scx/catalog.json` replaces it whole. Its recommended list holds the
profiles Pearl offers, Default first:

- **Default** is the kernel's own scheduler: no sched_ext scheduler runs.
- A plain profile, such as `scx_cosmos`, starts a scheduler with its own
  defaults. Its id is the scheduler's name.
- A custom profile starts a scheduler with options, under an id of its own.
  Only the administrator's catalog may hold them, since their options run as
  root on any user's say-so.

A recommended scheduler that is not installed is listed as **Not installed**
and cannot be chosen. Pearl does not hard-code any of this; when scx changes
its catalog, Pearl shows the new one.

## How a profile is applied

Choosing a profile runs `pkexec scxcli start ID`. scxcli writes the
scheduler's resolved path and the profile's options to `/etc/default/scx`,
clears `SCX_SCHEDULER_OVERRIDE` and `SCX_FLAGS_OVERRIDE`, and enables and
restarts `scx.service`; `start default` disables the unit and clears the
selection. scxcli takes the id only and reads the command from the installed
catalog, so its polkit action `org.sched_ext.scxcli.start` allows this
without a password for active local sessions. The choice persists across
reboots and applies to every user, before anyone logs in.

The unit's file holds a command, not an id, so Pearl finds the selected
profile by its command: the scheduler with exactly the profile's options.
scxcli writes the resolved path into the file and lists each profile's
resolved executable, so when both are known they must be the same file; a
bare name, or a profile whose scheduler is not installed, matches by name
only, which Pearl shows but never acts on. When several profiles stand for
one command, all of them are marked: the file cannot say which was picked.
A command no profile stands for, such as one started with `scxcli run`, is
shown as **Custom**.

What is selected (the next start, `next`) and what runs are different
things. What runs is scxcli's verdict (`current.scheduler` and
`current.running`: the unit's main process, with the kernel reporting it
attached), and the flyout and Settings mark the profile for what runs. When
the file was changed while the unit runs, the status says what the next
start will run.

`scxcli stop` stops the unit and keeps the selection, for a baseline
measurement say. Pearl shows that profile as **Selected, stopped**, dimmed in
the flyout, with an amber dot; choosing it starts it again.

That holds while the unit is enabled, as `scxcli start` leaves it: the next
boot brings the scheduler back. A runtime enablement (`systemctl enable
--runtime`) counts too, but lasts only for the current boot.

A command in the file that nothing starts is different. scx ships
`/etc/default/scx` naming a scheduler (`SCX_SCHEDULER=scx_cosmos`) while
`scx.service` stays disabled, so on a fresh system the kernel's own
scheduler runs and nothing will start Cosmos; an administrator may equally
have written a scheduler there without enabling the unit, and the two
cannot be told apart, by a bare name, an absolute path or otherwise. So
Pearl does not guess. When systemd reports the unit inactive, not enabled (nor
`--runtime`), its last run did not fail and its environment could be read
whole (no `config_error`; `next` is incomplete otherwise), **Default** is shown as what
runs, and the command `scx.service` is configured to run next (from the
file, or from an `SCX_SCHEDULER_OVERRIDE`/`SCX_FLAGS_OVERRIDE` in systemd's
environment) stays on show as what a manual start would
run: the status says "scx.service is set to run Cosmos, but it is not
enabled", and Settings marks that profile **Configured, not started at
boot**. Choosing the profile starts and enables it. A run that failed is
still that profile's failure, enabled or not: a manual `systemctl start`
of a disabled unit that fails shows as failed, not as Default, and one
that systemd reports active before scxcli has been asked again shows as
starting. A
distribution that enables `scx.service` by default does start the shipped
scheduler at every boot, and Pearl then shows it as running.

A start scxcli refuses (an id the catalog no longer has, a configuration it
cannot write, a dismissed password prompt) is not a failed scheduler:
scxcli checks before it touches the unit, so whatever ran before still runs.
Pearl shows the error and reads the state again, and does not fall back to
Default.

## Editing profiles

**Edit profiles** in Settings > System > CPU Scheduler adds, edits, deletes
and reorders profiles for every user. Pearl takes the catalog in use from
`scxcli catalog show`, replaces its recommended list and sends it back with
`pkexec scxcli catalog save`, which validates it and installs it as
`/etc/scx/catalog.json`. The catalog's other lists (featured, hidden, stable
and experimental: the scx maintainers' word on the schedulers) are kept as
they are. **Restore defaults** runs `pkexec scxcli catalog reset`, so the
shipped catalog is used again. Both change what any user may run as root, so
their polkit action, `org.sched_ext.scxcli.catalog`, asks for an
administrator password (kept for a few minutes). Choosing a profile, edited
or not, still needs none. Right-clicking the bar widget, or **Edit
profiles...** at the end of its flyout, opens this page.

The editor offers the installed schedulers the catalog does not hide, in the
order scx lists them, marking the experimental ones and those the catalog
does not know. A profile without options is a scheduler with its own
defaults; giving a plain profile options, or another scheduler, makes it a
custom profile with an id of its own. Options may contain only letters,
digits and `-_=.,:/+`, at most 32 of 256 characters each.

Editing the command of the profile the unit runs starts it again under its
new command, and deleting it starts Default. A selection that is stopped or
failed is left as it is: an edit never starts a unit that `scxcli stop`
stopped. When several profiles stood for the command that runs, Pearl starts
nothing while one of them still stands for it, and nothing either when none
does, since which one was picked is not on record. The save can wait on the
password prompt for long, so once it is done Pearl asks `scxcli get --json`
again and starts the profile only if the command it decided on still runs:
a scheduler someone started, switched or stopped meanwhile with scxcli or
scxtui is left alone. The same holds for **Restore defaults**.

A catalog larger than `scxcli catalog save` reads (64 KiB) is refused before
any password is asked for.

scxcli has no conditional write, so Pearl asks for the catalog again right
before saving and refuses when it changed since the list was built; an edit
dialog refuses in the same way when the profiles, or the schedulers it
offers, changed while it was open, instead of editing another profile. The
dialog keeps its own copy of what it was opened on, since every new listing
replaces the old one. The window between that check and the save is still
not closed: it includes the time the password prompt is open, so an edit
another administrator makes then is overwritten. Closing it needs a
conditional save in scxcli itself, such as an expected hash of the catalog
checked under its own lock. Default is what Pearl switches back to when a scheduler fails,
so it cannot be edited, deleted or moved; it stays first. The shell and
Settings watch both catalogs and `/etc/default/scx`, so changes made with
`scxcli`, scxtui or by hand show up at once.

Profiles edited in Pearl before it used the scx catalog were kept in
`/etc/pearl/scheduling-profiles.json`. Pearl no longer reads that file; add
the profiles again in Settings, which keeps them in `/etc/scx/catalog.json`.

## Status

A profile shows as running only once the kernel reports its own scheduler
attached in `/sys/kernel/sched_ext/root/ops`; any other scheduler shows as
**Custom**. Pearl takes systemd's D-Bus signals for the unit and the kernel's uevents
(`SUBSYSTEM=sched_ext`, sent whenever a scheduler attaches or detaches) as the
moments to ask `scxcli get --json` what runs. Every change of the unit's
state, its main process or how its last run ended raises one of those
signals, and every attach or detach a uevent, so while both work Pearl does
not poll. The signals need the unit's proxy, its Service proxy (how its
runs end, and systemd's restart count) and the manager's `Subscribe`, made
against systemd's current bus name. Until all three work —
systemd is not on the bus yet, a proxy cannot be made, `Subscribe` fails,
systemd left the bus — Pearl asks scxcli every 5 seconds and, at each of
those, tries to connect again. When systemd takes its name, under another
bus name than the connection was made against (re-executed or restarted),
or while the connection is not whole, Pearl makes the proxies anew and
subscribes again; polling stops only once every step of that attempt
worked, and the state is read once then, since signals may have been
missed. A result from a superseded attempt is discarded. Pearl lists the
profiles again with `scxcli list --json` when a catalog or the unit's
environment file changes. Those files, and their directories, may not exist
yet: a fresh system has no `/etc/scx` until the first `scxcli catalog save`,
and GIO's monitor on a file in a missing directory reports nothing, so Pearl
watches the deepest directory that exists for the next part of the path and
moves the watch down when it appears (and up again when it goes).

When `scxcli get --json` fails, or cannot even be started, Pearl keeps the
last state on screen marked as not confirmed, with an amber dot, and asks
again after 1, 2, 4 and 8 seconds, then every 16 seconds until scxcli
answers. Nothing is concluded from such a state: what runs may have changed
outside Pearl since scxcli last answered, so neither a failure nor a restart
systemd counted is put on a profile then. Nor afterwards: who restarted in
that time is not on record (a crash may have brought up another command), so
the first confirmed state takes systemd's count as a new starting point.

systemd counts restarts of the unit, not of a command, so a restart is a
profile's crash only when the count grew between two states scxcli
confirmed in which the unit's main process ran the same command. Nothing
about a failure is concluded between scxcli's answers: a refresh on a
systemd signal pairs the new unit state with scxcli's previous answer,
whose selection may no longer be what the unit is about (someone started
another scheduler), so failures and restarts are judged only at the first
refresh after an answer, and not after one that something changed while it
was asked for: that answer may predate the change, and is shown but not
judged until the answer to the read asked for next. A scheduler that never attaches is judged on a
state asked for when its deadline passes. When the command changed between two answers (the file was
switched and a crash brought up the next command, or someone started
another), when the listing could not be had, or when a state was not
confirmed, the count is a new starting point. A scheduler that keeps
failing is caught at its next restart, or when the unit ends in failure. A listing that cannot be had is asked for again the same
way. The flyout and Settings rebuild their rows when the
list changes while they are open. A scheduler attached outside the profiles
is noticed at once, even while Default is selected; Default then stays selected and the status names
the other scheduler. Only if the uevent socket cannot be opened does Pearl
fall back to rechecking every 3 seconds. The bar widget's icon carries a dot:
green while the profile is running, amber while it starts, is stopped or
another scheduler runs, red after a failure. The flyout and Settings show the
scheduler, the version it reports and when it started, for example
"Running - scx_cosmos 1.1.7 - since 13:41".

## Failures

Pearl watches `scx.service` through systemd's D-Bus API. Any failure of the
selected profile switches back to Default, so a scheduler that keeps failing
is not started again at the next boot:

- the scheduler ends in failure, because it crashed, the kernel ejected it
  (for example after a runnable task stall) or systemd's restart limit was
  reached;
- systemd restarts it after such an exit, which Pearl notices from the unit's
  `NRestarts` count even when the restart succeeds;
- it is still not attached 10 seconds after the unit became active, or after
  it detached while the unit stayed active.

A unit that is not active is failed only when scxcli reports a `failure`
(its last run in this boot did not end in success) or systemd marks it
failed; one stopped cleanly was stopped on purpose. A scheduler that detaches and attaches again
within its own process is not a failure either. Schedulers do that when a CPU
goes offline or online, since the kernel unregisters a scheduler that does not
handle CPU hotplug itself.

Pearl then sends a notification, and the flyout and Settings say what
happened until another profile is chosen, for example "Cosmos stopped:
runnable task stall ... on CPU 6. Switched back to Default." The reason is the
sched_ext exit message or the scheduler's last error from the unit's journal
since the profile was selected, read a second after the failure so the exit
message has arrived. When the journal cannot be read, systemd's exit status is
used instead, such as "killed by SIGKILL repeatedly". Only the shell falls
back, so Settings does not repeat it. A failure while nobody is logged in is
handled at the next login if the unit is still failed.

## Settings

The System page in Settings lists the same profiles, with their descriptions.
Without scxcli it says that the scheduler catalog cannot be read. It uses the
same service as the bar widget, so a change made in either place appears in
the other.

## Tests

`src/services/sched_profiles.zig` is tested against scx's own contract
fixtures, copied into `tests/fixtures/scx` (see its README): the detection
cases' `scxcli get --json` output, the catalog files every scx tool accepts,
and a `scxcli list --json` document built with scx_catalog itself.
