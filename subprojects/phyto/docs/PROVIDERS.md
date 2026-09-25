# Optional context-menu providers

PDF/video rendering is a separate planned integration; see the
[PDF and video provider plan](PDF_VIDEO_PROVIDERS_PLAN.md). The context-menu
scripts described here are never automatically invoked to generate previews.

Phyto discovers installed applications through GIO for Open with; choosing an
application once does not change MIME defaults. Local terminal actions use the
first available executable among xdg-terminal-exec, ghostty, kgx, gnome-terminal,
konsole, foot and xterm. Programs receive argument vectors and a working directory.

Built-in optional adapters detect `file-roller` (Compress/Extract), `bulky`
(multiple-item Rename), and the GIO `admin` scheme (Open as administrator).
Mount/Unmount/Eject use GIO and native authentication dialogs. Missing programs
produce no menu entries. Remote URI support comes from the installed GIO backend.
No Nemo or Cinnamon process is required to run Phyto.

## User-installed scripts, sharing and custom actions

Install `.action` files in `$XDG_DATA_HOME/phyto/actions` (normally
`~/.local/share/phyto/actions`) or `/usr/share/phyto/actions`, then reopen Phyto.
For example, an explicitly installed script can expose a sharing command:

```ini
[Phyto Action]
Name=Share selected files…
Exec=/home/your-user/.local/bin/share-files -- %F
Selection=multiple
Directories=false
```

The executable must exist. `Exec` uses GLib argument tokenization; Phyto does not
invoke a shell. Quotes group literal arguments. Substitutions must occupy an
entire argument:

| Token | Expansion |
| --- | --- |
| `%F` | One local path argument per selected item |
| `%U` | One URI argument per selected item |
| `%P` | Local path of the captured containing directory |
| `%%` | Literal percent sign |

`Selection` accepts `single`, `multiple` (at least two), `any` (one or more), or
`none` (directory background). `Directories=true` restricts selected items to
folders. False allows both files and folders. Use `%U` for remote files. Scripts
must implement their own supported file types, confirmation, progress and errors.
Phyto does not record external script or archive changes in its undo journal.

Only these installed directories are searched: opening an arbitrary folder never
loads scripts from it. Discovery is capped at 64 providers, with each descriptor
limited to 64 KiB. Unknown substitutions and missing executables are rejected.
This is a Phyto format, not `.nemo_action`, Nemo's Python API or its GTK3 extension
ABI. No built-in upload service or sharing destination is configured.

## Templates and stored choices

New document includes an empty document and up to 30 regular files from the
XDG Templates directory, discovered on startup. Creating from a template uses the
same non-overwriting copy engine and conflict dialog as normal copies.

`$XDG_CONFIG_HOME/phyto/preferences.ini` stores menu visibility, sort choices,
bookmarks, favorites and pinned URIs. These are Phyto-owned lists, independent of
Nemo's metadata. Moves and renames performed in Phyto update exact matching URIs.
External renames cannot be followed automatically; remove/re-add those entries.
