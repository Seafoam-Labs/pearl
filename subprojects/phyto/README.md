# Phyto

A native **Zig 0.16.0 / GTK4** file explorer following Pearl's design, with
Nemo-inspired navigation. The revised layout is implemented: one navigation
and view toolbar, per-pane tabs, file content and an optional details sidebar.
There is no large Home/location heading or subtitle.

## Build and run

Use Zig 0.16.0 and GTK4/GLib development packages (verified with GTK 4.22.5 and
GLib 2.88.3). The manifest pins Pearl's Ghostty-generated GObject bindings.

```sh
cd subprojects/phyto
zig build -Doptimize=ReleaseSafe
./zig-out/bin/phyto
./zig-out/bin/phyto --light ~/Documents
```

Within this Pearl checkout, the existing dependency cache can be reused with
`ZIG_GLOBAL_CACHE_DIR=/home/zoey/Pearl/.cache/zig` before the build command.
`zig build run -- PATH_OR_URI` also launches it. `--compact`, `--native-theme`,
`--width=N` and `--height=N` are available. The compositor can override initial
window size. Build installation stages a desktop entry and icon under `zig-out/`;
no MIME defaults or system packages are changed.

## Arch packages

Phyto is included in Pearl's release, `pearl-git`, and `pearl-intel-git`
PKGBUILDs. Launch `phyto` from the release package, or `phyto-git` from either
Git package. Both include a desktop launcher and icon; Git uses a separate
application identity so release and Git installs can coexist.

## Implemented

- Independent application windows, with no Pearl process or Aqueous API dependency.
- Real, asynchronous GIO folder enumeration and monitoring. Grid and detailed list
  use recycled GTK rows; names, MIME icons, sizes, dates and permissions are real.
- XDG Places, Home, local paths, supported GIO URIs, editable location, back,
  forward, parent and refresh. Missing/empty locations retain navigation.
- Multiple tabs in each pane, split view, active-pane targeting and independent
  view, location, history and selection state. Narrow windows retain both panes.
- Unicode case-insensitive filename filtering of the **current directory**, hidden
  files, native multi-selection, opening files through the default application,
  metadata details and Properties.
- Asynchronous create folder, rename and Trash. Single-file copy/paste uses a
  **window-local copy buffer**, with progress, cancellation and Skip/Keep both
  conflict choices. Existing files are never overwritten. Actions explain
  unsupported selections instead of silently doing something different.
- Pearl stock dark/light colors, compact density and optional native GTK theme.
  System GTK animation preferences remain respected; Phyto adds no animation loop.
- Native icon labels/tooltips, keyboard focus and adaptive Places navigation.

## Shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+L | Enter a path or URI |
| Alt+Left / Right / Up; F5 | Back / forward / parent; refresh |
| Ctrl+1 / Ctrl+2 | Grid / detailed list |
| Ctrl+F; Escape | Filter the current folder; clear search/location editor |
| Ctrl+H | Show/hide hidden files |
| Ctrl+T / Ctrl+W | New / close tab; last tab closes window |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab in current pane |
| Ctrl+N | New window |
| F3 / F6 | Toggle split / switch active pane |
| Ctrl+Shift+N; F2 | Create folder; rename selected item |
| Ctrl+C / Ctrl+V | Copy / paste one regular file within this window |
| Delete | Confirm moving the selected item to Trash |
| Alt+Enter | Properties |

More options contains the same file actions, appearance choices and split control.
Closing a window during an operation reveals its progress/cancel dialog; finish or
cancel the operation before closing. Executable files and desktop entries are not
launched by double-click.

## Review and validation

- [Native implementation report](docs/IMPLEMENTATION.md) and [native results](artifacts/native/results.json).
- [Native dark capture](artifacts/native/browse-dark.png), [split](artifacts/native/split.png),
  [light](artifacts/native/browse-light.png), [narrow](artifacts/native/narrow.png).
- [Longer-term implementation plan](docs/IMPLEMENTATION_PLAN.md).
- [Browser design reference](docs/mockups/index.html) and [mockup guide](docs/mockups/README.md).

```sh
zig build test
zig build integration -Doptimize=ReleaseSafe
```

The native suite uses Pearl's private Aqueous test harness, Python, `wtype`, `grim`,
`wlr-randr`, and the verified `.cache/aqueous-activity-production` tools. It runs on
its own display and D-Bus with disposable home/config/data directories. The app
itself has no such test dependencies. `integration` builds a separate instrumented
binary; the normal build contains no F12 test inspection shortcut.

This is the native design and local-browsing slice, not the complete planned
Nemo replacement. Recursive transfers/search, move/cut, undo, drag/drop, system
clipboard interoperability, replacement/merge, thumbnails, bookmarks, mount/eject
management, Trash restore, persisted preferences, localization, FileManager1 and
live Pearl appearance integration remain future work. Optional `trash:///` and
`network:///` browsing depends on installed GIO/GVfs support. Assistive technology,
physical mixed-DPI and remote-backend qualification remain manual release gates.
