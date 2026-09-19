# Initial application profiles

Templates copied from Seafoam-Labs/aqueous-dotfiles, commit
`76772cb9d009f971193b6fb2dbb56854055225d5`, `configs/matugen/templates/`.
Each profile carries the pinned source URL and the repository’s GNU GPL v3 text.
Equibop’s Midnight CSS additionally includes refact0r’s MIT notice from
https://github.com/refact0r/midnight-discord/blob/master/LICENSE.

Pearl changes: Zed display names identify Seafoam Pearl; Equibop’s metadata name
identifies Seafoam Midnight (Pearl). Zed and Starship depended on DMS-specific `dank16.colorN` roles absent from standard Matugen. Their terminal slots now explicitly use Matugen base16: 0→00, 1→08, 2→0b, 3→0a, 4→0d, 5→0e, 6→0c, 7→05, 8→03, 9→08, 10→0b, 11→0a, 12→0d, 13→0e, 14→0c, 15→07. This is a documented Pearl port, not a reproduction of DMS Dank16 colors. Other color expressions retain upstream Material roles.
Descriptors, variants, ownership destinations and activation guidance are Pearl
integration data. Dark-only CSS is not advertised for light mode. No Aqueous
profile exists. Fonts, plugins and remote CSS dependencies are not installed by
Pearl; review application-specific setup before activation.

Starship’s upstream Mint symbol used the lone surrogate `\udb82`, which is invalid TOML Unicode. The Pearl port uses the portable text `Mint` instead. Both generated variants are checked with an independent TOML parser.
