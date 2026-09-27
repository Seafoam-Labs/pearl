# Base Material assets, revision 1

DMS templates are pinned to AvengeMedia/DankMaterialShell commit
`72ca8a6876b014f5722a00f69301a5766653764e`, under
`quickshell/matugen/templates/`. The MIT license and Avenge Media notice are
included in each derived profile. Original in-file author notices are retained.
GTK colors also retain the upstream acknowledgement of thairanaru. Zed retains
its Adarsh219 author credit.

Pearl changes: display names and theme identities identify Pearl Material;
DMS `dank16.colorN` references use Matugen base16 roles with this ANSI mapping:
0→00, 1→08, 2→0b, 3→0a, 4→0d, 5→0e, 6→0c, 7→05, 8→03, 9→08, 10→0b,
11→0a, 12→0d, 13→0e, 14→0c, 15→07. This retains the existing Pearl terminal
mapping, including shared normal/bright chromatic slots; it does not reproduce
DMS Dank16 harmonization. Foot selects the matching dark/light section. VS Code
JSONC comments are removed so shipped outputs are strict JSON. Pywalfox uses an
empty wallpaper metadata string; Pearl never interpolates an unescaped path.

Neovim, lualine, Starship's minimal prompt, the VSIX manifest, profile manifests
and the target integration are authored for Pearl. Neovim has no DMS settings
or base46 dependency. The VSIX contains only declarative theme assets.

Fluxer and Steam templates are the existing attributed Seafoam ports from
Seafoam-Labs/aqueous-dotfiles commit `76772cb9d009f971193b6fb2dbb56854055225d5`,
`configs/matugen/templates/`, with GPL-3.0-only license and attribution retained
in their profile directories. Both currently support dark mode only.

`palette.json` is reproducible with `scripts/generate-material-palette.py`, using
Matugen 4.2.0 and seed #6750a4. Its 13 shell projections and corresponding
background/surface-tint aliases are overridden with the exact compiled Material
colors. Other Material roles, base16 and tonal palettes retain that generated
seed's values. These are fixed render inputs, not a claim that every supplied
role is derived from one untouched Material color algorithm invocation.

Assets are embedded in the binaries and installed under share/pearl/material for
inspection and attribution. The `pearl.material.*` catalog namespace is reserved;
user or package files cannot replace embedded profiles.
