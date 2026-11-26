# Coral Workspace performance

The runs of the incremental transcript renderer met the plan’s one-second warm launch and 50 ms tree and history targets on this machine. Session switching had the longest observed main-loop gap, reaching 74 ms when leaving or restoring a large conversation. The table gives milliseconds.

| Renderer and run | Warm document presentation, range | Expand folder, max gap | Load history, max gap | Typing to presentation, p95 | Switch sessions, max gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline 1 | 112.9–119.4 | 20.82 | 6.02 | 28.83 | 52.65 |
| Baseline 2 | 112.3–117.2 | 21.00 | 53.12 | 28.65 | 47.43 |
| Incremental 1 | 112.6–120.6 | 25.15 | 5.64 | 31.88 | 51.04 |
| Incremental 2 | 112.5–117.6 | 25.28 | 5.56 | 29.50 | 74.03 |
| Project rail and styled transcript | 107.6–119.3 | 23.23 | 5.55 | 27.57 | 51.02 |

The baseline used the transcript renderer from commit 61e211ca. That renderer replaced text after the first differing byte. The incremental version retains the matching trailing text, so prepending a history page preserves GTK’s existing paragraphs, layout and text marks. The runs are individual observations on one machine. The raw measurements include the priming launches, all sample counts, medians, 95th percentiles, maxima and measured binary hashes. [Measurements](../artifacts/development-workspace/performance.json)

## Workload and instrumentation

The AMD Ryzen 9 9950X3D host ran kernel 7.3.6-1.1-devario, Zig 0.17.1 in safe release mode, GTK 4.24.1, GtkSourceView 5.22.0 and libsoup 3.8.1. The editor occupied a 1400×860 window on a private Aqueous headless 1440×900 Wayland output at 60 Hz using Cairo. A loopback OpenCode fixture supplied synthetic messages.

Each trial created a fresh Git checkout containing 50,000 tracked files. One priming launch populated the profile and filesystem caches. Three further launches opened the same document. Timing began just before creating the process. A measurement-only entry point used the production workspace module, located the mapped document, requested a redraw and recorded the compositor’s presentation timestamp for that frame.

On the final launch the driver expanded a 1,000-file directory, loaded 19 earlier pages above the initial 100-message page, typed 35 characters with 32 ms between inputs, selected the other session, and returned. Each session received a stream event every 25 ms. The test checked that the text buffer contained the full 2,000-message thread and observed fresh history requests from both sessions on the incremental runs.

The gap columns give elapsed time between consecutive callbacks of a high-priority five-millisecond GLib heartbeat during each operation. These intervals include main-context scheduling and OS latency. Typing latency begins at GTK key capture and ends at the presentation timestamp for the requested frame. The headless compositor supplies that timestamp. A physical display has additional latency.

## Reproduce

From `subprojects/coral`, run the following with an Aqueous prefix that provides the private desktop harness.

```sh
zig build workspace-profile -Doptimize=safe -- --aqueous-prefix /path/to/aqueous/prefix --output /tmp/coral-profile
```

The output directory contains `measurements.json`, the measured phase intervals and the compositor and editor logs. The fixture removes its temporary checkout after the run.
