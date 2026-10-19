# CPU scheduler profiles

CPU scheduler profiles let people choose how the system schedules work, such
as Default, Low latency or Power saver, without picking sched_ext schedulers and
options themselves. The distribution maps each profile to a scheduler command
line and can change that mapping as schedulers evolve.

Profiles are offered by the `scheduler` bar widget (**Settings -> Bar & dock ->
Add widget -> CPU Scheduler**). It shows the active profile, and clicking it opens a
flyout with the profiles and their descriptions. The widget appears only when a
profile file is installed.

## How a profile is applied

Pearl runs schedulers through `scx.service` from the scx package, which starts
`$SCX_SCHEDULER $SCX_FLAGS` from `/etc/default/scx`. Pearl owns that file:
selecting a profile rewrites it, enables `scx.service` and restarts it.
A profile with `"action": "stop"`, such as **Default**, disables
`scx.service` instead, returning to the kernel's built-in scheduler (EEVDF). The choice persists across reboots and applies to
every user, before anyone logs in.

The file is written by `pearl-scheduling-helper`, installed in
`/usr/lib/pearl`, which Pearl runs through `pkexec`. The helper accepts only a
profile id and reads the command line from the system profile file, so users
can choose among the configured profiles but cannot run other commands. The
polkit action `org.aqueous.Pearl.Scheduling` allows this without a password for
active local sessions. The helper also clears `SCX_SCHEDULER_OVERRIDE` and
`SCX_FLAGS_OVERRIDE` from the systemd manager and stops `scx_loader.service`, so
no other mechanism replaces the selected profile.

Hand edits to `/etc/default/scx` are replaced the next time a profile is
selected. A scheduler started some other way is shown as **Custom**.

## Profile file

Pearl reads the first of these files that exists:

1. `/etc/pearl/scheduling-profiles.json` (administrator)
2. `/usr/share/pearl/scheduling-profiles.json` (distribution default)

Git builds use `/etc/pearl-git` and `share/pearl-git`. There is no per-user
file, because profiles run as root.

```json
{
  "version": 2,
  "profiles": [
    { "id": "default", "label": "Default", "action": "stop",
      "description": "The kernel's built-in scheduler (EEVDF), for everyday use." },
    { "id": "latency", "label": "Low latency", "sched": "scx_eevdf",
      "args": ["--slice-us", "1600", "--disable-cgroups"],
      "description": "Fastest response for interactive work, audio and multimedia." }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `version` | Must be `2`. |
| `id` | Lowercase letters, digits and `-`, at most 32 characters; unique. |
| `label` | Button text, at most 64 characters. |
| `description` | Optional, at most 256 characters; shown in tooltips and for the active profile. |
| `sched` | Scheduler binary name starting with `scx_`, found in `/usr/bin` or `/usr/local/bin`. |
| `args` | Optional list of arguments, one per element. Each may contain only letters, digits and `-_.=,:+/%@`, with no spaces. |
| `action` | `"stop"` returns to the kernel's default scheduler; it cannot be combined with `sched` or `args`. |

A file holds one to eight profiles. If it has no `stop` profile, Pearl adds
**Default** first, so returning to the kernel's scheduler is always possible.
The shipped profiles have their own **Default** for this.

## Failures

Pearl watches `scx.service` through systemd's D-Bus API. If the selected
scheduler stops while it should be running, because it crashed, the kernel
ejected it, or systemd's restart limit was reached, Pearl sends a notification
and shows the profile as stopped. It does not retry on its own; choosing a
profile again restarts it.

## Settings

When a profile file is installed, the scheduler page in Settings lists the same
profiles, with their descriptions, in place of the scx_loader scheduler editor.
It uses the same service and helper as the bar widget, so a change made in
either place appears in the other.
