# Context-menu implementation

2026-09-20 · Zig 0.16 / GTK4. The compact browsing layout remains intact, without
the removed Home heading/subtitle.

Scope: working Phyto workflows inspired by Nemo, not one-to-one compatibility,
as clarified during implementation.

## Delivered behavior

| Plan milestone | Implementation |
| --- | --- |
| M0 reference | Nemo 6.6.4 (Arch package 6.6.4-1.1) informed the inventory. Phyto uses its own GTK4 actions and provider format; exact Nemo menu or extension parity is not an acceptance requirement. |
| M1 menus and targets | Native GtkPopoverMenu for grid/list items, background, Places/bookmarks, devices, location and tabs. Secondary click preserves an existing multi-selection; an unselected item becomes the sole target. Menu/Shift+F10 and touch long-press share target resolution. |
| M2 operations | Asynchronous system clipboard, recursive copy/move, multi-selection, folder paste, explicit destinations, duplicate/link, collision Skip/Keep both/Cancel, progress/cancellation and a 32-group session undo/redo journal. |
| M3 open/recovery | MIME application intersection and one-off chooser, count confirmation above five opens, terminal detection, documents/templates, aggregate Properties, batch Trash, Restore/Restore to, permanent deletion and Empty Trash. |
| M4 surfaces | Persisted bookmarks and custom names, GIO mounts/volumes, location copying, clicked-tab duplication/reordering/closing/moving between panes, filtered-result parent navigation. |
| M5 preferences | Advanced-menu and permanent-delete visibility, checked view/sort state, descending/folders-first, pinned ordering, favorites, and selection preservation during sorting. |
| M6 integrations | Dependency-detected archive/Bulky/admin adapters and explicit Phyto script/sharing action descriptors. See [provider contract](PROVIDERS.md). |
| M7 qualification | Automated unit, native behavior/layout and packaging checks; native screenshots and remaining manual/provider qualification below. |

## Architecture and guarantees

`src/context.zig` owns referenced GFiles and metadata with stable tab IDs and
navigation generations. Recycled row indices never become operation operands.
`src/core/context.zig` centralizes capability rules. Keyboard, overflow and popup
commands share dispatch and capability checks. Unknown metadata disables affected
actions until asynchronous discovery completes. Menu dismissal, selection,
navigation and monitor changes invalidate pending menu discovery.

`src/operations/engine.zig` runs GIO work in GTask workers. Each job owns its source
and destination list. Directory copy does not follow symlinks, and rejects copying
a parent into itself, including destination-parent symlink aliases. Existing
items are not overwritten or merged. Copies preserve ordinary mode bits and
modification times where the backend supports those attributes. Special file
types report an unsupported operation instead of being read as ordinary files.

A cross-filesystem move verifies source and destination contents before deleting
the source. Its final source-removal phase is non-cancellable. Failed partial
copies attempt cleanup only of their own newly created destination. Per-item
success, skip, failure and cancellation are reported; successfully moved cut
entries are removed from the clipboard only if its owner/content has not changed.

Undo fingerprints include contents, directory membership, symlink targets,
identity, mode and modification time. Changed targets are left untouched. Undo
and redo retain partial receipts for retry; they never overwrite an occupied
original path. These checks are not an atomic transaction against simultaneous
external writers. There is no crash recovery journal. File copies do not promise
ACL/xattr, hard-link, sparse-file or ownership preservation.

Clipboard reads are asynchronous and bounded to 4 MiB/4,096 entries. Phyto exports
`x-special/gnome-copied-files` plus `text/uri-list`; plain URI lists mean Copy.
Known Cut payloads are required for Move. External programs use literal argument
vectors, including filenames containing spaces, quotes and shell syntax.

## Review and verification

ReleaseSafe build, 8 unit tests, 15 native context-menu check groups,
9 native browsing/layout groups and 6 packaging tests passed.
[Verification summary](../artifacts/context-menus/verification.json).

- [Native context-menu results](../artifacts/context-menus/native/results.json)
- [File menu](../artifacts/context-menus/native/file-menu-dark.png),
  [folder](../artifacts/context-menus/native/folder-menu.png),
  [multiple selection](../artifacts/context-menus/native/multiple-selection.png),
  [background](../artifacts/context-menus/native/background-menu.png),
  [list](../artifacts/context-menus/native/list-menu.png)
- [Browsing/layout regression results](../artifacts/context-menus/regression/results.json)
- [Original visual proposal](mockups/context-menus.html)

```sh
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
zig build test-context-menus -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe -- --output artifacts/context-menus/regression
# From the Pearl repository root:
python3 -m unittest tests.test_release_tools
```

Native tests run on a private compositor/D-Bus with disposable home/config/data,
using real files and `G_DEBUG=fatal-warnings`. Test instrumentation is compiled
only into the separate test executable. Package builds install the production
binary. Release/Git/Intel Git recipes include Phyto and advertise GVfs/file-roller
as optional dependencies.

## Explicit differences and remaining qualification

- File mutations are serialized per window; there is no parallel transfer queue.
  Replace/merge, crash resume and cross-window undo remain outside this delivery.
- Undo covers successful copy/move/rename/create/link operations for this session.
  Trash uses explicit Restore, and permanent deletion has no undo.
- Properties aggregates selected-file sizes and folder counts; it explicitly
  excludes recursive folder contents. It is a metadata viewer, not a permissions
  editor. Background metadata work is cancelled when its window closes.
- Pin/favorite/bookmark stores are local to Phyto. Exact URIs follow Phyto moves;
  external renames and descendants of moved bookmarked parents are not tracked.
  Missing locations remain visible so users can repair/remove them.
- Menu options group advanced actions; there are not individual toggles for every
  Nemo item. Sort/view entries use native checked actions. Symlink following opens
  the target's containing folder without selecting it.
- Optional providers use the documented Phyto format; Nemo's GTK3/Python extension
  ABI, `.nemo_action` format and automatic Nemo script discovery are unsupported.
  Sharing requires a user-installed provider. Physical device stop/power-off is
  not implemented separately from GIO Unmount/Eject.
- Physical removable media, authenticated remote/admin backends, missing-volume
  restore, actual archive/Bulky GUIs, screen readers, RTL/localization, touch
  hardware and physical mixed-DPI/200% text still need release qualification.
  Installed provider detection does not establish those end-to-end guarantees.
