# Native design implementation

September 20, 2026 · Native design, browsing and context-menu implementation.

The [context-menu report](CONTEXT_MENUS_IMPLEMENTATION.md) supersedes the original
single-file operation scope below and records current validation and differences.

The revised reference is now a standalone Zig/GTK4 application. The large location
heading/subtitle has been removed from all native browsing states. Navigation,
search, split/view/details controls and overflow actions share the top toolbar;
files follow directly below it. Smaller widths move Places into a popover, hide
optional toolbar controls and retain secondary actions in More options.

## Code and ownership

| File | Responsibility |
| --- | --- |
| `src/main.zig` | CLI, GtkApplication lifecycle, scoped CSS provider, independent windows |
| `src/window.zig` | Native layout, Places, tabs/panes, navigation, keyboard, details and dialogs |
| `src/tab.zig` | GtkDirectoryList → filter → sort → GtkMultiSelection; GtkGridView / GtkColumnView factories |
| `src/operations.zig` | Explicit-target dialogs, recursive worker jobs, conflicts and undo/redo |
| `src/core/model.zig` | Bounded history and filename validation, with allocator-checked tests |
| `src/ui.zig` | Widget constructors and metadata formatting |
| `resources/style.css` | Scoped Material dark/light and native-theme layout rules |
| `tests/native.py` | Private-display tests, real fixture files and native captures |

GTK's DirectoryList owns enumeration cancellation and file-monitor lifecycle.
It exposes each item's GFile through `standard::file`; actions use that identity
instead of constructing paths from display names. Filter/sort/selection models
and recycled factories serve both views. Directory changes coalesce to an idle
update, and an empty view retains useful loading/error/refresh states. History is
bounded to 64 locations per tab and each pane allows up to 32 tabs.

A tab has a stable allocation while callbacks refer to it. Its root owns view
widgets, and explicit retained model references are released during destruction.
Closing a tab detaches its content before releasing it. Closing a window stops
monitoring and pending UI sources and disconnects its native layout signal. Async
mutations hold the application until completion. The current window stays alive
while a mutation runs and offers progress/cancellation if the user tries to close.

Only the compiled integration binary includes F12 JSON inspection. User-facing
controls execute the same code in both builds. The production executable does
not link layer-shell, Cinnamon, Nemo or Pearl services.

## Intentional differences from the browser reference

- Folder contents and metadata are real, so names/counts/selection differ by path.
- MIME artwork comes from the installed icon theme. Local raster thumbnails and
  image/text previews are implemented; unsupported types retain their MIME icons.
  See [preview implementation and validation](THUMBNAILS_PREVIEWS_IMPLEMENTATION.md).
- The current search filters filenames in the open directory. It is explicitly
  labeled as such; recursive search remains in the roadmap.
- Places includes real XDG locations and GIO URI entry points. Fictional devices
  and storage-capacity numbers are not shown.
- Transfer UI is backed by recursive batch GIO worker jobs. Collisions offer Skip and
  Keep both. Replace remains out of scope until replacement recovery is implemented.
- Appearance uses the stock Pearl palettes with explicit light/compact/native
  choices. It does not yet subscribe to the Pearl committed-appearance protocol.
- Each invocation opens its own application instance; this avoids crossing display
  sessions. Single-instance routing and FileManager1 remain future integration work.

## Validation

Run `zig build test` for the pure model checks. Run `zig build integration
-Doptimize=ReleaseSafe` for the separate native test binary on a private compositor.
The test report and unaltered window-region screenshots (plus a full-output
conflict capture) live in
[`artifacts/native`](../artifacts/native/results.json). All test filesystem writes
occur under a temporary home. Native runs use `G_DEBUG=fatal-warnings`.

The suite checks real enumeration, selection, view switching, hidden files, search
and empty results, tab/pane independence, errors and history, copy byte integrity,
collision handling, folder creation, rename, rapid navigation, clean teardown,
large-directory row recycling, and dark/light/compact/native/narrow layouts.
The newer context-menu suite adds explicit-target, clipboard, recursive transfer,
undo, collision, provider and Trash coverage; see its report for current evidence.

Accessibility roles and labels use native GTK widgets. Physical screen-reader,
RTL/localization, mixed-DPI, remote mounts, power interruption and broad filesystem
fault-injection remain release qualification work. Failed/cancelled copy jobs attempt to remove destinations they created.
Filesystem changes by other processes, backend failures and power loss cannot
provide transactional rollback or crash-resume guarantees.
