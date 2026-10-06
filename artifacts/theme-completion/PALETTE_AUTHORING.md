# Palette authoring acceptance

Verified October 6, 2026 with Pearl 0.2.2, Zig 0.16.0 and Matugen 4.2.0.

The full ReleaseSafe build and these targets passed:

- `test`
- `test-theme-discovery`
- `test-theme-packages`
- `test-matugen`
- `test-base-material-profiles`
- `test-theme-publishing`
- `test-theme-github`
- `test-custom-themes`
- `test-theme-completion`

[acceptance.json](acceptance.json) records the desktop checks and tested binary
digests. The new screenshots show the
[Settings palette editor](session/local-palette-editor.png) and
[isolated watched CLI preview](session/watched-author-preview.png).

The desktop test creates a palette through Settings, previews edits without
changing committed preferences, saves it, and applies it with inherited
application templates. It then checks atomic live edits, explicit terminal
colors, hover colors, manual/Off precedence, preserved unsaved drafts,
invalid-to-valid recovery, rapid replacements, and restart with a missing source.
The watched CLI preview uses a separate palette and leaves the active palette,
preferences, application files, and shared draft unchanged.

All four palette JSON examples in the tutorial validate with the built CLI.
`packaging/install.sh` successfully staged the complete package under `/tmp`;
both authoring documents match the installed copies in `/usr/share/doc/pearl`,
and the staged author tool reports version 0.2.2.

The broader `test-preferences` target fails at its popup-hide check with
`UnknownCompletion` (`test_preferences.py:140`). The same failure reproduces
on an untouched HEAD checkout, so it remains a pre-existing test failure.

Custom palettes provide exact semantic and terminal colors. Additional Matugen
tone ramps retain the built-in Material ramps; the compiler does not claim to
generate new perceptual ramps from three colors. Application output still follows
the selected template, activation requirements, and conflict protections.
