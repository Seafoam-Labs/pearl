# Phyto: Nemo-style context menus

Status: implemented with tracked parity and qualification differences, 2026-09-20.
See [implementation and evidence](CONTEXT_MENUS_IMPLEMENTATION.md).
User clarification: functionality must work in Phyto; one-to-one Nemo parity is
not required. The original parity inventory below is retained as design context. [Open the review mockup](mockups/context-menus.html).

## Outcome and reference

Add context menus throughout Phyto with familiar Nemo file-management actions,
selection behavior, and keyboard access, presented through Pearl's GTK design.
Retain the compact navigation toolbar and file content immediately below it;
the removed Home heading and subtitle stay removed.

Nemo's visible menu depends on selection, backend capabilities, preferences, and
installed extensions. Its upstream [view actions](https://github.com/linuxmint/nemo/blob/master/src/nemo-view.c)
and [menu preferences](https://github.com/linuxmint/nemo/blob/master/libnemo-private/org.nemo.gschema.xml)
are the behavioral reference, inspected on the date above. The references track
`master`, not a pinned release. Before implementation, record a Nemo release or
commit and capture its selection/background menus with default preferences and
with optional items enabled. Record enabled extensions separately. The layouts
below are Phyto proposals; they do not claim every Nemo installation displays
identical items or ordering.

Treat parity as three deliverables: common file actions (M1–M3), location/device
and convenience actions (M4–M5), then integrations (M6). M1 alone is an initial
menu release; completion of this plan requires the later deliverables or explicit
tracking of the remaining differences. Do not claim complete Nemo compatibility
on the strength of a visually similar menu.

## Current code and required changes

| Current implementation | Consequence |
| --- | --- |
| `src/tab.zig`: `GtkDirectoryList`, filter/sort models, shared `GtkMultiSelection`, recycled grid/list factories | Hit testing must resolve the displayed item after filtering/sorting; model indices cannot become persistent action targets. |
| `Tab.pressed` only activates its pane | Add secondary-click handling for items, background, and empty/error states. |
| `src/window.zig`: `Command`, `GSimpleAction` registration, overflow menu and keyboard dispatcher | Reuse the action system; introduce shared target and enabled-state logic before adding menus. |
| `Operations.oneSelected`, window-local copy buffer, single regular-file copy and single-item Trash | Multi-selection and Nemo-compatible clipboard require backend work, not extra menu labels. |
| Properties reads the first selection; New tab/window uses the current directory | Add explicit selection/folder targets, aggregate Properties, and folder-specific opening. |
| `resources/style.css` already scopes popover palettes under `.phyto-root` | Extend existing styling and verify popover ancestry; avoid a second palette. |
| No undo, recursive transfers, bookmarks, restore, device management or menu preferences | Deliver these in named milestones; unavailable future features remain absent from shipping menus. |

## Menu inventory and proposed order

Semicolons separate sections; `>` denotes a submenu. The interactive mockup shows
an eventual design with fixture capabilities. Its milestone selector also shows
the smaller M1 menu. Labels use sentence case and ellipses for actions that need
further input. Shortcuts appear only when implemented.

| Context | Proposed menu, in order |
| --- | --- |
| One ordinary file | Open; Open with >; Cut, Copy, Copy to >, Move to >; Rename…, Duplicate, Make link; Pin/Favorite when supported; Move to Trash, Delete permanently… when enabled; Properties |
| One directory | Open, Open in new tab, Open in new window; Open in terminal; Cut, Copy, Paste into folder, Copy to >, Move to >; Rename…, Duplicate, Make link, Add bookmark; Pin/Favorite when supported; Move to Trash, Delete permanently…; Properties |
| Several items | Open with count-aware behavior; new tabs/windows only for all-directory selections; Cut, Copy, Copy to >, Move to >, Duplicate; Move to Trash, Delete permanently…; Properties for the entire selection. Rename requires an actual bulk-rename provider. |
| Background, including an empty directory | New folder…, New document >; Paste; Undo/Redo when available; Open in terminal; View >, Sort by >, Show hidden files; Properties of this directory |
| Trash item(s) | Restore, Restore to…; Delete permanently…; Properties including original location. Normal Cut, Rename, Paste and creation are absent. |
| Trash background | Empty Trash…; View >, Sort by >; Properties. Empty Trash is disabled when empty. |
| Symlink | Normal item actions applied to the link, plus Follow link to original. A broken link still supports rename/removal/Properties. |
| Search result | File actions plus Open containing folder. The current filename filter retains the current directory as background target; future recursive search backgrounds must not imply a writable directory. |
| Places/bookmark | Open, Open in new tab/window; Open in terminal for a local directory; Rename bookmark…, Remove bookmark; Properties. Built-in Places cannot be renamed or removed as bookmarks. |
| Device/mount | Open/new tab/window when accessible; Mount, Unmount, Eject or safely stop according to capabilities; Properties. Avoid duplicate unmount/eject choices where eject already unmounts. |
| Location button / future breadcrumb segment | Open in new tab/window, Open in terminal, Copy location, Properties of that segment. Editing the path keeps GTK's text-edit menu. |
| Tab | New tab, Duplicate tab; Move tab left/right, Move to other pane when split; Close tab, Close other tabs. Target the clicked tab. These are explicit Phyto proposals to review against Nemo's tab behavior. |

Nemo's [sidebar implementation](https://github.com/linuxmint/nemo/blob/master/src/nemo-places-sidebar.c)
provides the separate bookmark/device reference. File removal and bookmark
removal must remain distinct actions with distinct labels.

Submenu rules:

- **Open with:** enumerate applicable GIO applications, use the intersection for
  a multi-selection, then Other application…. Choosing once does not change MIME
  defaults; setting a default is a separate explicit choice. Show an application
  chooser when no default exists. Preserve the existing executable/desktop-entry
  activation policy until a separate trust/run design is implemented.
- **Copy to / Move to:** Other pane only in split mode, accessible bookmarks and
  Places, then Choose folder…. Snapshot the destination as well as the sources.
  Reject self-copy, moving a parent into its descendant, and invalid targets.
- **New document:** Empty document plus files from the XDG Templates directory;
  template creation uses normal collision and filename validation paths.
- **View / Sort by:** stateful actions for icon/list, name/size/type/modified,
  ascending/descending, folders first. This extends today's fixed name sort.
- **Optional extras:** Duplicate, Make link, Copy to/Move to, permanent deletion,
  pinning/favorites and integrations get menu visibility preferences in M5/M6.
  Omit empty submenus and redundant separators. The mockup enables advanced
  options for review; defaults should keep frequent actions easy to scan.

## Selection, target, and input contract

1. Secondary-click an unselected item: activate that pane, select just that item,
   then open its menu. Secondary-click an already selected item: preserve the
   whole selection, including selections outside the visible viewport. A
   secondary double-click must never open a file.
2. Secondary-click background: activate the pane, clear its file selection, and
   target its directory. Do this equally in grid whitespace, list whitespace,
   empty folders and no-results views. Column headers and scrollbars are separate
   hit zones; do not mistake them for file/background targets.
3. A click on any cell in a list row targets that row. Grid label/icon/padding
   inside a tile share one target. Blank tile spacing targets the background.
4. Menu key and Shift+F10 open at the focused selected item, or the view for a
   background menu. If a focused row is outside the current selection, select it
   first. Scroll an offscreen anchor into view. Preserve normal editable-widget
   context menus and shortcuts in path/search/name fields.
5. Native arrow navigation, Enter/Space activation, Escape dismissal and submenu
   navigation remain available. Dismissal returns focus to the original target
   if it survives, otherwise the originating view. Touch long-press uses the same
   target resolver and cancels when a scrolling gesture wins.
6. Opening a menu captures referenced `GFile` targets, pane/tab identity and
   navigation generation. Actions never reinterpret their operands through
   `Window.current()` after the user changes tabs or panes.
7. Close and invalidate the menu on tab close, navigation, selection change,
   view switch, target disappearance or parent destruction. Monitor/clipboard
   updates can change sensitivity in place; avoid changing row ordering under
   the pointer. Cancel pending discovery on dismissal and ignore late callbacks.
8. Revalidate capabilities when activating. Filesystem operations remain the
   final authority when permissions or mounts change after the menu opens.
   Report failures against the captured filenames; never operate on replacements
   merely because they occupy an old row index.

## Action state and operation behavior

| Condition | Menu behavior |
| --- | --- |
| Read-only destination or no directory target | Disable creation/paste and explain the restriction in accessible help. Source actions depend on their own capabilities. |
| Metadata or clipboard pending | Paint immediately from known state; disable affected actions until discovery finishes. No synchronous remote I/O during popup. |
| Unsupported URI/backend | Hide irrelevant actions; retain useful Open, Copy location and Properties where possible. Do not infer writability from `file://` alone. |
| Mixed selection | Enable a batch action only when every target is supported. If a backend reports unknown capability, query asynchronously or let an explicit operation report failures; never silently narrow to the first item. |
| Mutation already running | During M1, disable conflicting mutations and expose File operations. After the queue arrives, allow independent jobs under its conflict policy. |
| Empty or unsupported clipboard | Paste remains visible but disabled in valid directory contexts. Folder-target Paste does not use the currently open directory. |
| Trash unavailable | Explain that Trash is unsupported; permanent deletion stays a separate explicit command and confirmation. |
| Target changed during work | Keep per-item success/failure receipts, refresh affected views, and retain failed cut items. No automatic retry against a newly selected file. |

M2 replaces `Window.clipboard: ?*GFile` with system clipboard support for a URI
list and copy/cut intent, including Nemo interoperability. Verify the actual
formats used by the chosen Nemo revision; distinguish copy-only URI payloads
from a recognized cut payload. Read asynchronously, bound payload size/item
count, and treat text paths as text unless explicitly parsed as a file transfer.
Use content providers and clipboard change notifications; validate with a real
second process. This is separate from a window-local buffer.

The operation engine must accept explicit source lists and destination folders,
handle recursive directories and symlinks, and never silently overwrite.
Cross-filesystem move removes a source only after successful destination copy;
failed/cancelled items retain their sources. Conflicts offer Skip, Keep both and
Cancel; add Replace/merge only alongside defined recovery and tests. Track
partial destinations and clean up only files created by that job. Duplicate,
Make link, template creation and batch Trash reuse the engine.

Undo/Redo records successful reversible operations, checks that destinations have
not been changed by another process, and reports conflicts. Permanent deletion
has no undo promise. Keep Phyto's current Trash confirmation until receipts and
undo are reliable; later make confirmation a preference. Delete permanently and
Empty Trash always identify the target/count and require a confirmation with
Cancel as the default. Restore uses backend-provided original location data and
handles missing parents, unavailable mounts and name collisions; Restore to…
lets the user choose another destination.

## Zig/GTK structure

Use Zig 0.16.0 and the existing pinned GObject bindings. No Nemo runtime or GTK3
widgets are added. [GtkPopoverMenu](https://docs.gtk.org/gtk4/class.PopoverMenu.html)
can render action-backed menus; [Gio.Menu](https://docs.gtk.org/gio/class.Menu.html)
provides sections and submenus. Use those APIs with the existing `GSimpleAction`
registration rather than maintaining separate button callbacks for each surface.

| File | Planned responsibility |
| --- | --- |
| `src/core/context.zig` (new) | Pure context kinds, capability rules and action availability; exhaustive state tests. |
| `src/context_menu.zig` (new) | Own snapshot, menu model, popover, cancellables and teardown; model generation and action dispatch. |
| `src/actions.zig` (new) | Extract stable action IDs, target resolution, labels, shortcut/state/enablement handling from `window.zig`. |
| `src/tab.zig` | Factory setup/bind/unbind/teardown hooks, item/background hit resolution, focus anchoring and navigation generation. |
| `src/window.zig` | Window action registration, Places/location/tab integration, overflow and shortcuts sharing the same availability rules. |
| `src/platform/clipboard.zig`, `applications.zig` (new) | Cross-process transfer formats; MIME chooser and terminal launch adapter using argument vectors, not shell interpolation. |
| `src/operations.zig` initially, then `src/operations/` | Explicit-target jobs, recursive transfer queue, receipts, conflicts and undo; preserve compiling intermediate commits. |
| `src/platform/trash.zig`, `bookmarks.zig`, `volumes.zig` (new) | Restore/empty operations, persisted bookmarks, capability-driven GIO mount operations. |
| `resources/style.css` | Scoped menu layout and states for stock dark/light, compact and native GTK. |
| `tests/context_model.zig`, `tests/context_native.py` (new) | Capability tests and private-session tests of targets, actions and lifecycle. |
| `build.zig` | Include pure tests in `zig build test`; add a dedicated native context-menu test step. |

A snapshot owns strong references to source `GFile`s and destination plus a
stable tab ID/generation; it must not retain a `GtkListItem` index or a raw `Tab`
pointer after teardown. Event handling resolves the current bound item on each
click. Connect controllers once in factory setup; update associations during
bind and clear them on unbind. Claim only the handled secondary-click/long-press
sequence so primary selection, activation and rubber-band selection still work.
Test all list columns and avoid GTK-private widget names for hit testing.

Menu actions resolve a live context token to the snapshot. Activation transfers
owned operands to the job before popover teardown. Keyboard/overflow actions
create a fresh snapshot for their own invocation and pass through the same
capability checks. Closing a popover releases its references exactly once;
closing a tab/window disconnects controllers and cancels pending work before
freeing their state. Async jobs follow the application's existing hold/release
lifetime policy.

## Pearl presentation and review artifacts

Use the [existing Phyto design contract](IMPLEMENTATION_PLAN.md#3-pearl-design-contract)
and [Pearl component guidance](../../../docs/COMPONENTS.md). Menus use container
surfaces, opaque text, primary focus and semantic error colors. Default rows are
44 logical pixels; compact rows are 36. Use 12 px corners, 8 px section spacing,
14 px body labels, 16 px symbolic icons where useful, and a trailing shortcut
column. These are size floors; translated labels and 200% text must grow rows.

Anchor to the click or focused item and let GTK constrain the popup to the
available surface. Long menus must scroll. On narrow windows, submenus may use
GTK's menu pages rather than overflow offscreen. Native theme mode inherits
system colors. Disabled labels remain readable; destructive intent also has an
explicit label and confirmation. Menus never contain a big folder heading.

[The offline mockup](mockups/context-menus.html) has file/folder/background,
multi-selection, Trash, read-only, bookmark, device and tab scenarios, M1 versus
target scope, light/dark and compact switches. It is a visual review aid, not a
native implementation or filesystem simulation. Proposed additions in the
mockup are labeled as such outside the application window. Existing browsing
mockups remain unchanged.

## Delivery sequence and acceptance

| Milestone | Deliverable | Exit evidence |
| --- | --- | --- |
| M0 · Reference and contracts | Record Nemo revision, preference/extension inventory, screenshots, approved menu ordering and action matrix. | Every referenced action is classified as present, new backend, optional integration or explicit difference. |
| M1 · Context menu foundation | Grid/list/background and keyboard menus; explicit-target Open, folder new tab/window, existing single-file Copy/Paste, single rename/Trash, new folder, directory/selection Properties; lifetime and state rules. | Recycled rows, inactive pane, empty/error/filter states and disappearing targets cannot misdirect actions. M1 omits unsupported batch mutation; it never presents single-file support as batch support. |
| M2 · Clipboard and operations | Cross-process Copy/Cut/Paste, recursive/batch copy/move/Trash, Paste into folder, Copy to/Move to, duplicate/link, job receipts, collision/cancellation and guarded undo. | Byte/metadata and source-retention checks across same/different filesystems; real Nemo clipboard exchange in both directions. |
| M3 · Opening and recovery | Open with, safe terminal adapter, New document/templates, bulk Properties, Trash restore/Restore to/Empty Trash and permanent deletion. | MIME defaults stay unchanged for one-off opening; quoted/non-ASCII filenames launch correctly; restore and deletion fixtures pass. |
| M4 · Remaining surfaces | Places/bookmarks, device actions, location menu, tab menu and filtered-result parent navigation. | Bookmark edits survive restart; mount errors remain recoverable; tab actions target the clicked tab; stable and Git launch commands work. |
| M5 · Preferences and convenience | Menu visibility settings, stateful sorting, Pin/Favorite, undo/redo presentation and persistence. Define pin ordering and favorites storage/provider explicitly. | Preference round trips; sorting/pinning preserve selection; renamed or vanished favorites reconcile; no empty sections. |
| M6 · Optional integrations | Archive actions, bulk rename provider, Scripts/custom actions, sharing/provider entries, administrative-location support. | Each provider has dependency detection, target validation, missing-provider behavior and end-to-end fixtures. Remaining Nemo differences are documented. |
| M7 · Qualification | Complete native and visual matrix, accessibility review, packaging regression and updated implementation report. | All criteria below pass, and provider-dependent gaps are named in release notes. |

Dependencies: M0 → M1 → M2 → M3; M4 can follow M1 but device work needs the
capability model; M5 requires M2/M4; M6 depends on the relevant operation and
platform adapters; M7 qualifies the combined result. Implement the context-menu
foundation first, then backend features in independently reviewable commits.
This reuses the broader roadmap's P3/P4/P5/P6 work; do not build a competing
transfer or mount subsystem solely for menus.

M6 scope is deliberate: Nemo [custom actions](https://github.com/linuxmint/nemo/blob/master/files/usr/share/nemo/actions/sample.nemo_action)
can be conditional on selection and environment, so installations differ. Use
an isolated, explicit Phyto provider contract for installed/user-configured
actions; never execute scripts merely because a browsed directory contains them.
Launch with argument vectors and explicit working directory. A compatibility
adapter for `.nemo_action` requires documented supported fields and parsing tests;
do not promise binary compatibility with Nemo's GTK3 extensions. Archive and
bulk-rename menus appear only with a working provider. An administrative action
would open an authenticated GIO administrative location in an unprivileged
Phyto process; investigate backend support in M6 and report unsupported systems.
Running the entire GUI as root remains outside the original Phyto scope.
Desktop-only wallpaper/icon-arrangement menus belong to Pearl's desktop, not
this file browser. Pin/Favorite interoperability with Nemo is an explicit M5
investigation; local Phyto support does not imply shared storage.

## Verification matrix

- **Pure model:** zero/one/many/mixed selection, folder versus regular file versus
  symlink, clipboard absent/copy/cut/unknown, read-only/unknown capabilities,
  trash/search/device/bookmark contexts, preference masks, no empty sections.
- **Native input:** actual secondary clicks on grid icons and each list column,
  selected/unselected rows, blank space, empty and error views; keyboard Menu and
  Shift+F10, Escape/focus restoration, inactive split pane, scroll/recycling,
  path/search editing, submenu edges and long-press/scroll arbitration.
- **Lifetime:** open menu then navigate, filter, sort, rename/delete from another
  process, close tab/window, switch pane, remove a mount or finish clipboard
  discovery. Run with fatal GTK warnings and verify no stale callback/action.
- **Real operations:** independent source/destination fixtures, mixed batches,
  Unicode/spaces/newlines/leading dashes, symlink loops, deep folders, collisions,
  permissions, disk full, cross-filesystem move and cancellation. Compare bytes
  and verify failed/cancelled moves retain sources. Never substitute tests against
  the user's own files, Trash or MIME defaults.
- **Integration:** second-process clipboard and actual Nemo; MIME/terminal/provider
  launch fixtures; bookmark persistence; private Trash/GVfs session; injectable
  mount failures plus a manual removable-device check.
- **Presentation:** dark/light/native, normal/compact, narrow and edge placement,
  200% text, long translated labels/RTL, reduced motion and keyboard-only use.
  Record native screenshots and perform an Orca pass on names, disabled states,
  submenu navigation and restored focus. HTML captures cannot certify GTK/AT.
- **Packaging:** unit/native targets pass; release/Git/Intel Git staging retains
  Phyto launcher/icon identities. Add optional provider dependencies only when
  a supported adapter ships; do not require Cinnamon/Nemo for core menus.

Definition of done: every enabled item acts on its displayed targets, ordinary
keyboard/overflow/menu entry points agree, batch actions process the entire
captured selection, errors preserve unaffected files, and the parity matrix
records all remaining optional or intentional differences. Update the README,
implementation report and native evidence; remove claims superseded by the new
clipboard and operations backend.
