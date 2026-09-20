# Dome implementation status

September 20, 2026 · native development build 0.1.0

Dome is a working standalone Zig/GTK4 application. The browser study remains a
visual reference; `artifacts/native/` contains captures of the actual application.
This is a first native implementation, not a claim of complete Mission Center
parity or a fully qualified distribution release.

## Delivered behavior

| Area | Native implementation |
| --- | --- |
| Overview | Live resource cards, bounded history, process/thread counts, uptime, three busiest processes with navigation to details |
| CPU | Overall and logical-processor plots, separate I/O wait, physical core count, CPU 0 frequency/base frequency and cache instances |
| Memory | Total, used, available, cached and swap; RSS process rows; PSS and command line only for a selected process |
| Storage | Whole-device selection, read/write rates, activity, average response time, capacity; readable local mounted filesystems |
| Network | Individual interfaces, receive/send, lifetime totals, state, addresses, hardware address and readable link speed; bytes/s or bits/s summaries |
| GPU | Multiple DRM adapters; available AMD sysfs metrics; Intel discovery/frequency; optional NVIDIA NVML helper with deadline and stale-result handling |
| Sensors | Named hwmon temperature and fan readings, with per-sensor history |
| Processes | Recycled sortable/filterable GTK column view, user filter, cgroup application grouping, details, pidfd-based end/force-stop confirmations |
| Services | Optional user/system systemd manager, search, selection, asynchronous start/stop/restart, authorization errors, owner-change recovery |
| Preferences | Atomic versioned storage; interval, theme, compact rows, network/CPU units, graph duration, columns, primary process sort, page and window size |
| Interface | Nine pages, light/dark/native GTK colors, narrow navigation/details, compact summary, keyboard shortcuts, scalable GTK fonts |
| Packaging | Standalone staged install and Pearl release/Git/Intel-Git package integration; separate Git executable and desktop identity |

Application grouping requires an application cgroup/scope. Uncertain processes
remain individual rows. Group details show up to 20 members; controls require the
raw individual process view. Group RSS can double-count shared pages.

The reference is the feature list on the [Mission Center homepage](https://missioncenter.io/),
reviewed September 20, 2026. No upstream release equivalence is asserted. Its GPU,
wireless enrichment and application identity coverage are broader than the
implemented Dome providers. Dome's systemd page is an additional roadmap feature.

## Build and architecture decisions

The tested toolchain is Zig **0.16.0**, GTK **4.22.5**, GLib **2.88.3**, x86-64
Linux. The highest GTK API version used is **4.12** (`gtk_css_provider_load_from_string`);
older GTK/GLib combinations have not been build-tested. Process control requires
Linux pidfds. Unsupported control fails without falling back to unsafe PID signals.

The implementation uses a single Zig `@cImport` of the installed GTK/GIO/Cairo and
Linux headers instead of the proposed generated GObject dependency. This keeps
the standalone build free of fetched dependencies. `platform/c.zig` contains
header-only compatibility definitions for Zig 0.16's C translator and the local
GLib/GTK headers. Runtime libraries are ordinary dynamically linked system
libraries; no GTK, GObject or libc implementation is copied into Dome. Portability
of this import shim is an explicit follow-up gate.

`core/model.zig` owns pure parsing, identities, rates and histories. A collector
worker builds arena-owned snapshots, retains its previous baseline and publishes
one reference through a mutex-protected latest-snapshot mailbox. The main loop
takes that reference; a newer pending snapshot replaces and frees the old one.
Workers never access GTK widgets. The UI owns table models, widget references and
history buffers. Row data is released by GObject destroy callbacks; factories
bind/unbind recycled labels. New rows enter the list store in a single splice.

The collector bounds process/device enumeration and uses actual monotonic elapsed
time. CPU topology changes, counter rollback, resume and detected suspend gaps
reset affected rates. Histories contain at most 1,202 points each, with at most
512 identities. CPU plots display the first 128 logical processors; enumeration
supports up to 4,096. A collection cap is reported in the status line.

NVIDIA calls execute in a disposable copy of the running executable, launched
through `/proc/self/exe`. The UI kills a helper after 1.2 seconds, retries no more
frequently than every five seconds and rejects results older than ten seconds.
The core worker never waits for this provider. Shutdown joins the worker, cancels
service requests, kills/drains a running helper and releases models/histories.

## Metric and capability boundaries

- CPU busy time excludes idle and I/O wait and does not double-count guest time.
  Process CPU is a percentage of total sampled online capacity by default; the
  one-core mode is explicit. A missing rate is shown as a dash, not zero.
- Memory in use is `MemTotal - MemAvailable`. Cache is not a disjoint category
  from available memory. PSS is nullable when `smaps_rollup` cannot be read.
- Disk sectors use 512-byte units. Activity is time with I/O in flight, not a
  statement of maximum performance. Physical and stacked devices are not summed.
- Network uses the documented `/proc/net/dev` fallback and `getifaddrs` rather
  than rtnetlink. Interfaces are identified by ifindex, address and sysfs identity;
  disappearance or a changed identity resets baselines. An interface recreated
  between samples with the same identity can escape detection; rtnetlink lifecycle
  generation tracking remains a follow-up. No per-process network attribution
  or sum of overlapping physical/bridge/VPN traffic is claimed.
- GPU fields are independent nullable capabilities. AMD reads available busy,
  VRAM, hwmon temperature/power/frequency. Intel currently exposes discovery and
  readable frequency only; device utilization/VRAM is not inferred from clients.
  NVIDIA supplies available utilization, video, memory, temperature and power.
- Only local ext4, XFS, Btrfs and VFAT mounts are queried with `statvfs`. Remote,
  FUSE and pseudo filesystems are skipped. The disk page labels the mount list as
  covering all devices; mount capacity is refreshed on opening the page.
- Process controls retain a pidfd from confirmation through dispatch and verify
  PID/start time. PID 1 and Dome itself are protected. The UI restricts controls
  to individual processes owned by the current user. Kernel authorization errors
  are reported; there is no root helper or automatic SIGTERM-to-SIGKILL escalation.
- Service calls are typed asynchronous D-Bus operations. The installed manager's
  `ListUnits`, `Subscribe`, `StartUnit`, `StopUnit`, `RestartUnit` and `JobRemoved`
  signatures were checked by read-only introspection. An accepted job is distinct
  from a successful `JobRemoved` result and observing its final state. Denial
  messages persist across automatic list refreshes. All action tests use a private mock manager.

## Evidence and remaining gates

See the [native evidence report](../artifacts/native/README.md),
[hardware record](../artifacts/hardware.json),
[Cairo benchmark](../artifacts/graph-benchmark.json) and
[lifecycle measurements](../artifacts/soak/results.json) and
[post-fix lifecycle measurements](../artifacts/soak-final/results.json).

Core/parser tests, disposable-child pidfd tests and the native private-session
suite exercise real collection, pause/manual/resume, all pages, 10,000 synthetic
rows, service operations/denial/disappearance, theme modes, 480-pixel layout,
200% GTK font size, and helper timeout. Synthetic rows and special keys exist only
in the separately instrumented integration build and are visibly labeled.

The following remain open; the original milestone exit criteria are not all
marked complete:

- Live Pearl committed-appearance protocol integration; current themes use
  built-in Pearl colors or native GTK settings. Standalone startup needs no Pearl.
- Intel hardware qualification and richer Intel/DRM engine providers; broader AMD
  and NVIDIA driver/version coverage, hotplug and suspend on physical hardware.
- Desktop-entry/ancestry enrichment beyond cgroups, NetworkManager Wi-Fi details,
  optional process GPU columns, per-field diagnostic reasons and last-success
  timestamps rather than the current nullable values and page-level explanations.
- Orca walkthrough, GTK X11 smoke test and translations. Neither Orca nor an Xvfb
  executable was available locally. Native high-contrast/scaled-font screenshots
  and ordinary GTK accessibility semantics do not establish complete accessibility.
- Deterministic filesystem/hotplug fixture injection, longer parser fuzzing,
  minimum-version distribution builds and a clean full Pearl `makepkg` run.
- The repository's source license/release gate. Dome follows
  `LicenseRef-Pearl-Unlicensed`; no new project-wide source license is asserted.
  Original SVG/CSS/code are included, with no copied Mission Center or Phyto assets.
  GTK/GLib/Pango/Cairo and optional NVIDIA libraries retain their system-package
  licenses. Metadata declares CC0-1.0, consistent with the repository packaging.

D0–D3 functionality and substantial D4/D5 functionality are present. D4–D6
qualification remains limited to the available machine and recorded tests.
