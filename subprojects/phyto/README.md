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
- Local JPEG/PNG/WebP/GIF thumbnails, larger image and UTF-8 text previews in
  details, and a Space-key preview window. Preview generation is bounded and
  asynchronous, with shared memory and freedesktop disk caches.
- XDG Places, Home, local paths, supported GIO URIs, editable location, back,
  forward, parent and refresh. Missing/empty locations retain navigation.
- Multiple tabs in each pane, split view, active-pane targeting and independent
  view, location, history and selection state. Narrow windows retain both panes.
- Unicode case-insensitive filename filtering of the **current directory**, hidden
  files, native multi-selection, opening files through the default application,
  metadata details and Properties.
- Native right-click, Menu-key and Shift+F10 menus for files, background,
  Places/bookmarks, devices, location and tabs. Targets remain tied to the clicked
  files and originating tab; multi-selection works in grid and list views.
- System Copy/Cut/Paste, folder-specific paste, recursive batch copy/move,
  collision Skip/Keep both, cancellation, duplicate/link, and guarded session
  undo/redo. Existing destinations are never silently overwritten.
- Open with, terminal, empty documents/templates, aggregate Properties, Trash
  restore and permanent deletion with confirmation. GIO capabilities govern
  availability; optional integrations depend on installed providers.
- Persisted bookmarks, pinning/favorites, sorting and menu preferences. Archive,
  bulk rename and user-installed script/sharing actions have provider adapters.
- Pearl stock dark/light colors, compact density and optional native GTK theme.
  System GTK animation preferences remain respected; Phyto adds no animation loop.
- Native icon labels/tooltips, keyboard focus and adaptive Places navigation.

## Shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+L | Enter a path or URI |
| Alt+Left / Right / Up; F5 | Back / forward / parent; refresh |
| Ctrl+1 / Ctrl+2 | Grid / detailed list |
| Space | Preview one selected file; Escape closes the preview |
| Ctrl+F; Escape | Filter the current folder; clear search/location editor |
| Ctrl+H | Show/hide hidden files |
| Ctrl+T / Ctrl+W | New / close tab; last tab closes window |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab in current pane |
| Ctrl+N | New window |
| F3 / F6 | Toggle split / switch active pane |
| Ctrl+Shift+N; F2 | Create folder; rename selected item |
| Ctrl+C / Ctrl+X / Ctrl+V | System clipboard Copy / Cut / Paste |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo completed reversible operations |
| Menu / Shift+F10 | Context menu for the focused target |
| Shift+F4 | Open local folder in an available terminal |
| Delete / Shift+Delete | Confirm Trash / permanent deletion (when enabled) |
| Alt+Enter | Properties |

More options contains the same file actions, appearance choices and split control.
Closing a window during an operation reveals its progress/cancel dialog; finish or
cancel the operation before closing. Executable files and desktop entries are not
launched by double-click.

## Review and validation

- [Native implementation report](docs/IMPLEMENTATION.md) and [native results](artifacts/native/results.json).
- [Native dark capture](artifacts/native/browse-dark.png), [split](artifacts/native/split.png),
  [light](artifacts/native/browse-light.png), [narrow](artifacts/native/narrow.png).
- [Context-menu implementation and differences](docs/CONTEXT_MENUS_IMPLEMENTATION.md),
  [native menu captures](artifacts/context-menus/native/file-menu-dark.png), and [custom providers](docs/PROVIDERS.md).
- [Nemo-style context menu plan](docs/CONTEXT_MENUS_PLAN.md) and [menu review mockup](docs/mockups/context-menus.html).
- [Longer-term implementation plan](docs/IMPLEMENTATION_PLAN.md).
- [Thumbnails and file previews plan](docs/THUMBNAILS_PREVIEWS_PLAN.md).
- [PDF and video provider implementation plan](docs/PDF_VIDEO_PROVIDERS_PLAN.md).
- [Browser design reference](docs/mockups/index.html) and [mockup guide](docs/mockups/README.md).

```sh
zig build test
zig build integration -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
zig build test-previews -Doptimize=ReleaseSafe
```

The native suite uses Pearl's private Aqueous test harness, Python, `wtype`, `grim`,
`wlr-randr`, `wlrctl`, `wl-copy`/`wl-paste`, GVfs, and the verified `.cache/aqueous-activity-production` tools. It runs on
its own display and D-Bus with disposable home/config/data directories. The app
itself has no such test dependencies. `integration` builds a separate instrumented
binary; the normal build contains no F12 test inspection shortcut.

Recursive search, drag/drop, replacement/merge, localization,
FileManager1 and live Pearl appearance integration remain future work. Optional
Trash/network/admin support requires the relevant GIO/GVfs backends; file-roller
provides archive actions. Menu preferences live in
`$XDG_CONFIG_HOME/phyto/preferences.ini`; optional actions are described in
[PROVIDERS.md](docs/PROVIDERS.md). Full Nemo extension ABI compatibility is not
claimed. See the implementation report for operation limits and manual release
qualification still required.

## Thumbnails and previews

Use **File view options…** in More options to toggle local thumbnails or details
previews and set the image file-size cap (1–50 MiB). The background menu also
provides the two toggles. Explicit **Preview** (Space or the file context menu)
works even when automatic previews are disabled, including in narrow/split views.
Enter/double-click still opens the file normally.

Images retain their aspect ratio, transparency and orientation. GIF and WebP
previews are still images. Text previews show UTF-8 source without rendering
HTML/Markdown, limited to 64 KiB / 500 lines. Directories, symlinks, remote GIO
URIs, unsupported formats and special files retain icons. Known remote native
mounts are rejected when GIO reports their filesystem as remote. PDF and video
stills are the [planned provider extension](docs/PDF_VIDEO_PROVIDERS_PLAN.md),
not included in this release.

The helper runs in the same executable before GTK initialization, using the
pinned GdkPixbuf bindings (verified with GdkPixbuf 2.44.7). It enforces a 512 MiB
address-space ceiling, timeouts and image limits. The UI shares two decode jobs,
a 128-request queue and a 64 MiB texture-pixel cache across windows. Full previews
are capped at 2048 px; generated disk thumbnails have a 256 MiB ownership budget.
Cache-write errors leave previews usable. See the
[implementation report](docs/THUMBNAILS_PREVIEWS_IMPLEMENTATION.md) and
[native preview results](artifacts/previews/results.json).

The preview tests additionally use Python Pillow to encode JPEG/WebP/GIF fixtures.
Pillow is not an application dependency. Like the existing native suites, they
require local sockets for the private compositor/D-Bus and installed image loaders.
