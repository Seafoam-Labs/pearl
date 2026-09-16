# Pearl memory investigation — 2026-09-16

The main confirmed avoidable growth is allocator retention following UI churn.
The large wallpaper and GTK/NVIDIA graphics allocations account for another
substantial part of the footprint. These tests did not find accumulating
launcher widgets or old decoded wallpapers.

## Live desktop

Installed `pearl-git 1.0.0rc2.r35.g676224a-4`, PID 2695, approximately one hour
into the session. The source differences since that commit concern the greeter,
not the shell paths inspected here. See [host.json](host.json).

| Accounting | MiB |
| --- | ---: |
| `/proc/PID/status` VmRSS (also reported by ps) | 756.7 |
| Detailed smaps RSS | 600.0 |
| Detailed smaps proportional share (PSS) | 505.5 |
| Anonymous resident memory | 291.7 |
| `/dev/nvidiactl` resident mappings | 151.6 |
| Decoded wallpaper (`memfd:glycin-frame`) | 47.5 |

The last three rows are components, not additional totals. Other mapped memory
includes GTK, NVIDIA/LLVM libraries, fonts and stacks. Status and detailed smaps
counters differ on this process; neither is a measurement of live Zig objects.
Smaps RSS and anonymous memory remained unchanged across the idle observations.

The active JPEG is 7680 × 2160 RGB: 49,766,400 decoded bytes (47.46 MiB), despite
its compressed file being only 1,231,341 bytes. Exactly one decoded frame was
mapped. The renderer also has its own textures, buffers and caches.

## Controlled reproductions

All reproductions used the installed shell and CLI, the private headless
compositor harness, separate D-Bus and configuration directories, and the same
wallpaper. No host settings, service or process were changed. The private output
sizes and services differ from the live desktop, so absolute totals are not
predictions for the host.

The uninstrumented default-renderer run increased detailed RSS from 236.9 MiB
to 428.7 MiB when displaying the wallpaper. The Cairo run increased from
65.2 MiB to 126.1 MiB. These are different rendering configurations, not a
recommendation to change the desktop renderer. The private Vulkan run logged
`VK_SUBOPTIMAL_KHR` swapchain warnings; the lifecycle test still completed and
the shell exited successfully.

Across six image-to-solid transitions with each renderer, decoded frame counts
were always one with the wallpaper and zero after switching to solid. Old
decoded wallpapers therefore are released on these paths. NVIDIA mappings
also dropped on transitions, although some graphics allocation remained cached.

### Launcher lifetime and allocator retention

The diagnostic preload installs weak-reference callbacks on selected GTK object
constructors, and reports `mallinfo2()` on the private process's main loop.
After 120 opens/closes:

- All 120 launcher windows, string lists, selection models and list views had
  finalized. Only the four baseline wallpaper/bar windows remained.
- 54,420 GtkBoxes had been created and 54,396 finalized, leaving the same 24
  baseline boxes. This is allocation churn, not retained launcher row trees.
- Glibc reported 151.1 MiB of arena space: 39.3 MiB allocated and **111.8 MiB
  free inside the allocator**, plus 2.3 MiB of separate malloc mappings.
- Waiting roughly 36 seconds did not reduce RSS.
- A diagnostic `malloc_trim(0)` returned **57.4 MiB** to the OS. Fragmented free
  space remained. No trim was invoked in the user's desktop process.

| Same instrumented Cairo workload | Default allocator | `MALLOC_ARENA_MAX=2` |
| --- | ---: | ---: |
| RSS with wallpaper before launcher cycles | 127.0 MiB | 126.3 MiB |
| RSS after 120 launcher cycles | 323.1 MiB | 206.2 MiB |
| RSS after idle | 323.1 MiB | 206.2 MiB |
| RSS after diagnostic trim | 265.7 MiB | 191.7 MiB |

Limiting arenas reduced the end-of-workload RSS by **116.9 MiB** in this test.
This validates allocator retention as a significant contributor. It is not a
complete heap profile: allocations outside these tracked GTK types, library
caches and other shell interactions could still contain smaller leaks. The
host's precise free-versus-live heap split was not measured by attachment.

## Relevant ownership paths and follow-up improvements

- `src/desktop/launcher.zig:75`: each opening creates a new launcher, models and
  row widgets. `destroy()` disconnects signals; `free()` releases models and
  ranking state. Instrumentation confirms finalization on repeated close.
- `src/ui/surfaces/manager.zig:850`: `hidePopup()` destroys the surface; it does
  not retain hidden popup windows.
- `src/config/service.zig:308`: wallpaper decoding uses the original resolution.
  `validateProviders()` creates a texture and `removeLive()` destroys the previous
  job. Picture paintables are replaced in `manager.zig:305`.
- The current preferences job retains its preparation arena until replacement.
  This unnecessarily keeps the compressed wallpaper and temporary preparation
  allocations alive. For this static-theme JPEG the compressed input alone is
  only 1.17 MiB, so it cannot explain the observed hundreds of MiB.

The most promising measured mitigation is a bounded allocator arena count,
followed by reducing launcher allocation churn. It should be validated with
the production GPU renderer and normal interactive workload before making it a
launch default. Separating preparation scratch memory from committed preference
state would remove smaller avoidable retention. No production change was made.

## Reproduce

From the repository root, compile the diagnostic preload:

```sh
gcc -shared -fPIC -O2 -o artifacts/memory-investigation/heap_probe.so artifacts/memory-investigation/heap_probe.c $(pkg-config --cflags --libs gobject-2.0) -ldl
python3 artifacts/memory-investigation/probe.py cairo
python3 artifacts/memory-investigation/probe.py default
python3 artifacts/memory-investigation/probe.py cairo launcher
python3 artifacts/memory-investigation/probe.py cairo heap
python3 artifacts/memory-investigation/probe.py cairo heap 2
```

`probe.py` reads only the current wallpaper selection from the host. Each run
saves `samples.json`, compressed smaps snapshots and private-session logs.
The heap log's object counters are created/finalized for windows, string lists,
selection models, boxes, list views and CSS providers, in that order.
