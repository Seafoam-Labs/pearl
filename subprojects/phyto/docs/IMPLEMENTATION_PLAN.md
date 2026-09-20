# Phyto implementation plan

Status: native design and local-browsing slice implemented · September 20, 2026.
See [implementation status and limits](IMPLEMENTATION.md) and the
[native validation report](../artifacts/native/results.json). The full roadmap
below remains broader than this first implementation; P0–P7 are not all complete.

## 1. Product and decisions

Build **Phyto**, an independently launchable file explorer written in **Zig using
GTK4 and GIO**, in `subprojects/phyto/`. Carry Nemo's practical navigation and
file-management workflows into Pearl's visual language. Opening, browsing and
managing files must work without a running Pearl shell or Aqueous compositor.

Interpret “based on Nemo” as a behavioral reference and fresh implementation.
Nemo's upstream build is C with GTK3; embedding or porting its UI wholesale would
conflict with the chosen stack. Record an upstream commit and a behavior checklist
in P0 before implementation. No Nemo source, extension ABI or artwork is copied in
this proposal. If implementation later reuses upstream material, inventory its
individual license and attribution before adding it. See [upstream build](https://raw.githubusercontent.com/linuxmint/nemo/master/meson.build)
and [Nemo overview](https://github.com/linuxmint/nemo).

The target is a capable daily-use file manager, delivered in stages. The review
prototype is HTML/CSS with original SVG icons for easy inspection; production
will not embed a browser, Electron, JavaScript UI or a web view. Libadwaita is not
required by Pearl's design system. Use native GTK window decorations and controls.

## 2. Review package

Open [the interactive prototype](mockups/index.html). The review strip above the
window and the explanatory note below it are presentation tools, not application UI.

| Scenario | Capture | Review focus |
| --- | --- | --- |
| Home, icon view, selected file and details | [Dark](mockups/browse-dark.png) | Places hierarchy, breadcrumb, tonal content surface, metadata |
| Same layout in light mode | [Light](mockups/browse-light.png) | Equivalent contrast, selection and hierarchy |
| Detailed folder listing | [List](mockups/list.png) | Scan speed, columns, density, filename priority |
| Independent tabs in two panes | [Split](mockups/split.png) | Active pane, destination clarity, local navigation |
| Recursive filename search | [Search](mockups/search.png) | Search scope, result locations, clear exit |
| Copy progress and name collision | [Transfer](mockups/transfer.png) | Destination, operation state, explicit conflict resolution |
| 560-pixel window | [Narrow](mockups/narrow.png) | Places drawer, overflow controls and preserved content |
| Empty directory / denied access | [Empty](mockups/empty.png), [Error](mockups/error.png) | Useful next action, retained navigation |

Review the default density, lavender baseline, sidebar width, split-pane behavior,
details sidebar and conflict choices. These are proposed defaults, not recorded
approvals. Once reviewed, P1 captures the same fixtures in actual GTK; browser
screenshots alone never establish GTK feasibility or native accessibility.

## 3. Pearl design contract

Use these repository sources as the authority:

- [Visual specification](../../../docs/IMPLEMENTATION_PLAN.md#3-visual-and-interaction-specification).
- [Component and lifecycle guidance](../../../docs/COMPONENTS.md).
- [Semantic palettes](../../../src/theme/theme.zig) and [scoped CSS](../../../resources/style.css).
- [Settings application layout](../../../docs/STANDALONE_SETTINGS_APPLICATION_PLAN.md#window-layout) and [layout CSS](../../../resources/settings-layout.css).
- [Committed appearance contract](../../../docs/SETTINGS_FRONTEND_API.md#s2-read-only-appearance-and-activation).

| Design property | Phyto rule |
| --- | --- |
| Color | Read semantic surface, low, container, high, text, secondary, primary, on-primary, primary-container, on-container, outline and error roles |
| Dark baseline | Surface `#141218`, container `#211f26`, text `#e6e0e9`, primary `#d0bcff`, selection `#4f378b` |
| Light baseline | Surface `#fdf7ff`, container `#f3edf7`, text `#1d1b20`, primary `#6750a4`, selection `#eaddff` |
| Spacing / radius | 2, 4, 8, 12, 16, 24 logical pixels; 12 px components; 16 px outer window as in Settings |
| Type | Installed Inter, sans fallback; 12 px metadata, 14 px body, 16 px section labels, 20 px dialog and empty-state headings; respect system scaling |
| Icons | Consistent 16/24/32 px symbolic family, MIME icons from installed icon theme; original fallback artwork |
| Input targets | Primary controls and sidebar rows at least 44 px; default file rows 44 px, explicit compact rows 36 px |
| States | Hover 8%, focus/pressed 12%, drag 16% background state layers; separate visible focus outline from selection |
| Motion | At most 150 ms; disable transitions and animation for reduced motion; no decorative perpetual animation |
| Theme scope | Scope native styles under `.phyto-root`; keep foreground opaque; opaque window surfaces by default |

Default window: approximately 1180 × 760 logical pixels, clamped to usable space.
Use a 208–220 px Places sidebar, header/navigation, per-pane tabs, a scrolling file
viewport, and a fixed status bar. Keep view controls in the navigation toolbar;
identify the current folder with breadcrumbs and tabs, without a separate large
location heading or descriptive subtitle. Optional 248 px details sidebar summarizes the
selection without replacing Properties. File names get two lines in icon view,
ellipsis plus tooltip in list view, and full selectable text in Properties.

Use content-space breakpoints: below ~980 px, close the optional details sidebar;
below ~760 px, show Places as a dismissible drawer and secondary actions in an
overflow menu. Two panes need at least 320 px each after chrome; if they cannot
fit, show one pane plus a pane switcher, retaining both tabs, histories and jobs.
Do not discard split state on resize. At 480 px and 200% text scaling, wrap action
groups, prioritize Name over optional columns, and keep dialogs scrollable.

Material light/dark, dynamic palettes, native GTK themes, text size, compact mode
and reduced motion must all work. Native-theme mode supplies layout CSS only and
inherits system colors. Do not import shell opacity, layer-shell behavior or
wallpaper rendering into this ordinary application window.

## 4. Scope and Nemo parity

Nemo supplies the reference for back/forward/up/refresh, editable breadcrumbs,
bookmarks, GIO/GVfs locations and visible operation progress; its schema also
documents extra-pane and hidden-file preferences. See [overview](https://github.com/linuxmint/nemo)
and [preferences](https://github.com/linuxmint/nemo/blob/master/libnemo-private/org.nemo.gschema.xml).

| Capability | First usable slice (P2–P3) | Daily-use release (through P6) |
| --- | --- | --- |
| Navigation | Local home/path/URI, history, breadcrumbs, typed location, hidden files | Bookmarks, session restoration, removable and remote locations |
| Views | Virtualized icon and detailed list, sort, multi-selection | Compact density; persist per-folder view/sort with bounded cache |
| Workspace | Multiple windows and tabs | Two independently navigable panes with tabs in each |
| File actions | Open/Open With, new folder, rename, copy/cut/paste, Trash | Drag/drop, duplicate, links, properties, permissions when supported, guarded undo |
| Operations | Recursive copy/move, progress, cancellation and collisions | Multi-job center, partial-failure summary and last-window job handling |
| Finding | Type-to-select current folder | Explicit recursive filename search, scope/type filters, visible partial results |
| Desktop integration | Launcher entry, directory arguments and MIME launch | FileManager1, GTK bookmarks, mounts/eject, Trash restore |
| Appearance | Pearl stock palettes, keyboard and focus | Live committed appearance, native GTK theme, high contrast, localization |

Deferred after v1: Nemo extension/action compatibility, desktop icon ownership,
running as root, embedded terminal, archive mutation, batch rename, full-text
indexing, cloud-provider integrations and executable previews. Compact density
does not promise Nemo's separate compact-column view. “Open in terminal” launches
a configured terminal using an argv-based adapter for local folders; no shell
string interpolation. Archives can open in their registered application.
Recent locations can ship without a global recent-files index.

## 5. Interaction and behavior

### Navigation and selection

Each pane owns its tab set. Each tab owns location URI, back/forward history,
view/sort state, selection identities, scroll anchor, search and enumeration
generation. Switching panes changes the toolbar, shortcut target and status.
Show an active-pane accent and accessible label; moving the pointer alone does
not change the active pane. F3 opens/closes split view; shrinking only hides a
pane. New tabs duplicate the active location; explicit CLI paths override saved
state. Closing the last tab closes its window, subject to active-job behavior.

Single click selects, double click/Enter opens; Ctrl toggles and Shift extends a
range. Folder activation stays in its pane unless “Open in new tab/window/other
pane” is requested. Keyboard selection and scroll anchors survive sorting and
monitor updates by identity, never by row index. Open files through GAppInfo;
unknown types show an application chooser. Executable and desktop-entry launch
needs a deliberate action; never execute a downloaded file just to preview it.

| Shortcut | Action |
| --- | --- |
| Alt+Left / Right / Up; F5 | Back / forward / parent; refresh |
| Ctrl+L; Escape | Edit location; dismiss editor/search/dialog and restore focus |
| Ctrl+T / W; Ctrl+Tab / Ctrl+Shift+Tab | New / close tab; next / previous tab in active pane |
| Ctrl+N; F3; F6 | New window; toggle extra pane; switch active pane |
| Ctrl+1 / 2; Ctrl+H | Icon / list view; toggle hidden files |
| Ctrl+F; typing outside fields | Search folder recursively; type-to-select visible items |
| Ctrl+A / C / X / V; F2 | Select all / copy / cut / paste; rename |
| Ctrl+Shift+N; Delete; Shift+Delete | New folder; Trash; confirm permanent deletion |
| Ctrl+Z; Alt+Enter | Undo eligible completed action; Properties |

Translate UI labels, plural counts and errors; keep URIs untranslated. Announce
selection, loaded/partial result counts and job completion through native
accessible properties. Name every icon-only control. Context actions must also
be reachable by keyboard. Validate focus order with Orca in P7.

### File operations and recovery

All mutation entry points use one operation engine. Capture explicit source and
destination GFiles when a job is created, so changing tabs cannot redirect it.
Model states as queued → preparing → running → awaiting-decision → completed,
partially-completed, failed or cancelled. Count bytes when known; show “Preparing”
or item progress when a total cannot be determined. Throttle UI updates to 10 Hz.
Do not display a pause button until the engine supports resumable transfers.

The collision dialog shows both items' location, size, modified time and type.
Offer Skip, Keep both and Replace for files; directories get an explicit Merge
choice, and type mismatches require an explicit decision. Default focus is the
least destructive choice. “Apply to remaining conflicts of this kind” is scoped
to the current job. Replacement is never implicit and can invalidate undo.
Deletion uses Trash when available; failure to trash must never silently become
permanent deletion. Empty Trash and permanent deletion require confirmation.

Recursive copy belongs to Phyto: `GFile.copy_async` copies a file and is not a
directory-tree operation. Use asynchronous traversal, bounded work queues and
per-item outcomes. Prefer native move; cross-filesystem fallback copies an item,
verifies successful close/metadata outcome, then deletes only that source item.
Cancellation and failure must retain any source whose destination did not finish.
Never follow symlinks recursively by default. Reject copying a directory into
itself/descendants using identities and backend-aware ancestry checks; repeat
destination checks at execution to handle races. See [GIO copy contract](https://docs.gtk.org/gio/method.File.copy.html).

For supported local destinations, write to a uniquely owned temporary sibling
and commit with a backend operation whose overwrite semantics have been tested.
Remote backends have differing guarantees: advertise the actual outcome and
partial remnants rather than promising universal atomicity. Preserve timestamps,
modes and supported metadata; report unavailable preservation. Do not silently
claim hard-link, sparse-file, ACL or xattr preservation without backend tests.

Keep an in-memory undo journal of successful reversible rename, move, copy and
Trash operations. Before undo, verify recorded identities/versions; changed or
missing items produce an explicit conflict. Never delete a subsequently edited
destination as “undo copy.” Replacement, permanent delete and external changes
have no general undo guarantee. Persist a bounded interrupted-job receipt so a
crash can explain incomplete work; do not automatically resume destructive work.

Jobs belong to the application, not a tab. Closing the last window during work
offers Keep working, Cancel operations and close, or Return; hold GApplication
while work continues, with an operation-window entry point. Window close alone
does not discard a running transfer. No permanent background daemon is required.

### Search, locations and exceptional states

Ctrl+F searches names beneath the current directory, with a visible scope label,
cancellable traversal, hidden-file policy and path column. No content indexing
is implied. Do not follow directory symlinks, mount boundaries or remote trees
without explicit scope decisions. Show partial results and inaccessible-directory
counts, never “no matches” while still searching. Exit restores prior selection.

Places contains XDG user directories, GTK bookmarks, Trash, local volumes and
network entry points. Use `GVolumeMonitor`, GMountOperation and installed GVfs
backends for devices, SFTP/SMB and credentials. Feature availability follows the
backend; absent protocols explain how to install support. Never persist passwords
in Phyto preferences. Eject/unmount reports busy/failure and does not fabricate
success. Show stale/disconnected status if a viewed mount disappears.

Explicit states: loading, empty folder, no search matches, permission denied,
missing location, offline mount, read-only destination, disk full and cancelled
job. Retain breadcrumbs and a way back. Retry creates a new generation. Large
directories show incremental contents and a partial count until complete.

## 6. Architecture and dependencies

Pin Zig **0.16.0** and the same Ghostty generated GObject package/hash as Pearl's
[manifest](../../../build.zig.zon). Begin with Pearl's verified GTK **4.22.5** /
GLib **2.88.3** environment, rather than inventing a lower minimum. P0 records
the dependency matrix and proves the pinned bindings expose required APIs;
upstream documentation may describe newer libraries. Use one generated GTK/GIO
type universe. Generate any missing GIR binding reproducibly, with no handwritten
C bridge. All application and operation logic stays in Zig.

Only GTK4, GIO/GLib/GObject, Pango and required platform libraries are mandatory.
GVfs backends, thumbnail providers and configured terminals are optional runtime
capabilities. Aqueous, layer-shell, session-lock, Cinnamon and Nemo libraries are
not runtime dependencies. Build Phyto independently with its own manifest; a
future root convenience target may delegate without making the shell a dependency.

```text
subprojects/phyto/
  build.zig, build.zig.zon, .zigversion   # available; source layout below is the longer-term target
  src/main.zig                          # process and arguments
  src/core/{application,window,pane,tab,actions}.zig
  src/model/{file_item,directory,selection,history,search}.zig
  src/platform/{gio,volumes,bookmarks,desktop,clipboard,thumbnails}.zig
  src/operations/{engine,job,copy,move,trash,conflict,undo}.zig
  src/theme/{tokens,appearance,css}.zig
  src/ui/{window,sidebar,breadcrumbs,tabs,grid,list,details,dialogs}.zig
  resources/{phyto.gresource.xml,ui/,styles/,icons/}
  packaging/{org.aqueous.Phyto.desktop,org.aqueous.Phyto.metainfo.xml}
  tests/{unit/,integration/,fixtures/,visual/}
  docs/IMPLEMENTATION_PLAN.md, docs/mockups/  # delivered now
```

| Layer | Contract |
| --- | --- |
| Pure model | Testable Zig state machines for navigation, sorting, selection, job decisions and undo eligibility |
| GIO adapters | URI-based locations; GFileInfo identities and display names; cancellable async enumeration, metadata, monitors and mutations |
| View model | FileItem GObjects in GListStore → filter/sort list models → GtkMultiSelection; stable identities separate from labels |
| GTK views | GtkGridView / GtkColumnView with recycling factories, GtkPaned, GtkStack, GtkPopover, GtkSearchEntry, GtkDialog and GActions |
| Application | GtkApplication, normal toplevel windows, session-aware activation, application-owned jobs and teardown |
| Appearance | Validated immutable appearance state; process-local CSS provider; no file operation depends on the shell connection |

`GtkGridView` and `GtkColumnView` provide model-driven item factories; ensure
unbind removes handlers and textures before recycling. See [GridView](https://docs.gtk.org/gtk4/class.GridView.html)
and [ColumnView](https://docs.gtk.org/gtk4/class.ColumnView.html).

Use GIO async APIs for ordinary I/O, reading enumerator batches (initially 128)
and returning to the main loop between batches. Every request has a generation,
stable owner reference and GCancellable. Cancel on navigation/close, reject stale
completion, and still call the matching finish/cleanup path. GTK updates occur
only on the main thread. Worker results own copied data; raw row pointers never
escape to workers. Disconnect signals, cancel sources, finish pending callbacks
and release GObjects in a documented order. See [async enumeration](https://docs.gtk.org/gio/method.File.enumerate_children_async.html).

Monitor the active directory, coalesce events and rescan after overflow/invalidation.
Avoid periodic full-directory polling. Inactive tabs release heavy monitors or
refresh on activation. Initial limits: two transfer streams per job, four thumbnail
requests, 64 MiB texture LRU, 10,000 visible search results with an explicit limit
notice. Tune from measurements. Virtualization bounds widgets, not file metadata:
P2 measures 100,000 entries and must define a surfaced memory limit if necessary.

Use the freedesktop thumbnail cache/provider conventions. Never decode arbitrary
large images unboundedly on the GTK thread. Start with local image thumbnails
with size/time limits and MIME icons as fallback; remote previews are opt-in.
Properties uses cancellable metadata/directory-size work rather than blocking.

Clipboard and DnD share URI transfer parsing, including `text/uri-list` and the
GNOME copied-files cut/copy convention. Negotiate GTK/GDK native formats too.
Treat incoming data as untrusted, keep URI escaping distinct from display text,
handle non-UTF-8 local names via GIO, and clear cut styling only after successful
move. Drag modifier intent must resolve into an explicit copy/move/link action.

### Pearl appearance integration

P1 bundles a small attributed semantic token module and Phyto-specific scoped
CSS, with parity checks against Pearl's source. Avoid importing the whole theme
module transitively: it currently also imports preference validation. P6 adds
a read-only adapter to Pearl's existing committed-appearance handshake/events,
reusing or narrowly extracting the existing client/decoder after inspecting its
coupling. This is planned work, not an assumed standalone public theme service.
Honor protocol/session identity and never enter Settings editor pages, acquire
device leases or write Pearl preferences. If minimal sharing is not feasible,
document a bounded adapter before implementing it; any root extraction is a
separate, explicitly described patch.

Without Pearl, use system color-scheme/font preferences with stock Material or
native GTK mode. Connection loss retains the last validated appearance for the
process; browsing continues. Local Phyto view preferences are versioned under
XDG_CONFIG_HOME/phyto with atomic writes. Store no remote credentials. Persist
bounded local-location history only; private sessions disable history and restore.

### Application integration

Propose `phyto`, application ID `org.aqueous.Phyto`, desktop file and GApplication
identity aligned. Support `phyto [PATH_OR_URI…]`, `--new-window`, `--select URI`,
`--help`, `--version`; validate arguments and preserve activation tokens. Normal
launch reuses a window; `--new-window` is explicit. Implement FileManager1
ShowFolders, ShowItems and ShowItemProperties in P6 and test bus-name contention
with other file managers. Session routing must not activate a parent display from
a nested test session. Keep directory MIME default changes opt-in; installation
alone must not take over the user's default file manager.

## 7. Delivery sequence

Each phase produces working code, evidence and an updated parity checklist.
Dependencies are sequential unless noted. Rough effort ranges below are engineering
days for one developer, not calendar commitments; GVfs and operation edge cases
have the greatest uncertainty. Re-estimate after P0 and P3.

| Phase | Dependencies / estimate | Deliverables and acceptance |
| --- | --- | --- |
| P0 · Foundation | Design review; 2–3 days | Own Zig manifest, pinned bindings, GTK smoke window, GResource build, license/source inventory, frozen Nemo behavior reference. `zig build` and a pure-test target pass; launch/close under private Wayland with fatal GTK warnings. |
| P1 · Native design | P0; 3–5 days | Static GTK gallery for all supplied screens, stock dark/light and native theme, keyboard focus, reduced motion, compact/large text. Capture at 1180/760/480 widths and 1×/2×; compare actual GTK to mockups and record deviations. |
| P2 · Browse | P1; 5–7 days | Real enumeration, grid/list, hidden/sort, history, location entry, multi-selection, Open With, windows/tabs. Rapid navigate/close never applies stale results; 100k-entry fixture remains responsive with bounded realized rows. |
| P3 · Safe mutation | P2; 8–12 days | Recursive operation engine, create/rename/copy/move/Trash, conflicts, progress, cancellation, receipts, guarded undo. Fixture matrix covers no-loss cross-filesystem move, collisions, symlinks, disk full, permission failure and cancellation; no silent overwrite. First usable local alpha. |
| P4 · Workflows | P3; 4–6 days | Per-pane tabs, split state, clipboard/DnD, active-pane targeting, details/Properties, terminal action, filename search. Independent histories and resize retention pass; search cancellation and inaccessible paths are visible. |
| P5 · Locations | P4; 5–8 days | GTK bookmarks, Trash restore, volumes/mount/eject, optional SFTP/SMB, bounded thumbnails. Test disconnect mid-transfer and missing GVfs; restore collisions use the same engine. |
| P6 · Desktop integration | P5; 3–5 days | Read-only Pearl appearance, preferences, privacy option, desktop/AppStream assets, CLI, FileManager1 and package. Runs with Pearl stopped; installation preserves MIME defaults; nested sessions remain isolated. |
| P7 · Release qualification | P6; 5–8 days | Accessibility, translations, scale/theme/performance matrix, operation fault injection, packaging and manual removable/network checks. Resolve blocking defects and publish limitations, comparison captures and release checklist. |

Total planning range: **35–54 engineering days**, plus review and hardware/backend
availability. P1 is the first native visual review; P3 is the local alpha; P7 is
the daily-use release gate. Avoid expanding later scope while operation integrity
or keyboard navigation is incomplete.

## 8. Verification and release gates

Build, test and integration commands now exist. The separate gallery and visual
targets below remain planned; native captures currently come from `integration`:

```sh
cd subprojects/phyto
zig build -Doptimize=ReleaseSafe
zig build test
zig build integration
zig build gallery
zig build test-visual
```

Pure tests exercise URI/selection/history transitions, ordering, job state
machines, conflict choices and undo eligibility. Integration tests use disposable
trees, a private D-Bus session and nested compositor; no tests target the user's
home, mounts, clipboard or MIME settings. Use separate filesystems and constrained
storage fixtures to prove fallback and disk-full behavior. Assert source/destination
contents and identities, not merely callback success. Fault injection covers
late completions, process termination, monitor storms and remote disconnects.

Native UI checks cover shortcuts, focus restoration, tab/pane targeting, action
availability, dialog semantics and long/RTL/non-UTF-8 names. Repeat navigation,
window close and cancellation under allocator diagnostics and fatal GTK warnings.
Orca, actual drag/drop with another GTK application, physical removable media,
mixed-DPI displays and real SFTP/SMB remain explicit manual gates.

Provisional performance budgets on a recorded release-build SSD reference machine:
first usable local view within 500 ms warm / 1 s cold for 1,000 entries; initial
visible batch within 1 s for a 100,000-entry directory; 95th-percentile UI event
latency below 100 ms during enumeration/copy; thumbnail cache within 64 MiB; no
recurring directory scans or redraws in a settled window. Any required Pearl
connection heartbeat is measured separately from UI idle work. Record hardware, run count,
RSS and fully enumerated metadata memory separately. These are targets, not results.

Release requires completed local operation fault tests, all P1 scenes captured in
native GTK, no unresolved source-loss or unintended-overwrite defects, no known
keyboard-blocking paths, usable error recovery, reproducible dependency pins and
documented optional backend support. Track failures and open hardware checks in
`docs/VALIDATION.md` when implementation begins.

## 9. Original planning delivery and current implementation

Delivered here: plan, editable prototype, nine screenshot scenarios and a browser
review-check script/report. All file names, counts, transfer rates and filesystem
states in mockups are fictional. The prototype does not implement real filesystem
I/O, native GTK widgets, complete tab/history behavior, drag/drop, mount handling,
operation safety or screen-reader guarantees. Those belong to the gates above.

The original planning delivery contained no native code. A subsequent native
design/local-browsing implementation is now available; consult
[the implementation report](IMPLEMENTATION.md) for the delivered capabilities
and remaining work. The roadmap estimates and release gates above are retained
as targets, not assertions that every milestone has passed.
