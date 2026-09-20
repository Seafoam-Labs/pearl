# Native Phyto review

These are real GTK4 window captures produced by `zig build integration
-Doptimize=ReleaseSafe`. The file contents and filesystem are disposable test
fixtures; the application runs its real directory model and GIO actions. No Pearl
shell is running. The headless Aqueous compositor provides window decoration,
placement, keyboard input and screenshot capture.

| View | Capture |
| --- | --- |
| Updated toolbar and grid | [Dark](browse-dark.png) |
| Detailed listing | [List](list.png) |
| Independent panes | [Split](split.png) |
| Current-folder name filter | [Search](search.png) |
| Empty directory | [Empty](empty.png) |
| Missing location | [Error](error.png) |
| Single-file collision (full test output) | [Conflict](conflict.png) |
| Light stock palette | [Light](browse-light.png) |
| Compact list | [Compact](compact.png) |
| System GTK theme | [Native theme](native-theme.png) |
| 560-pixel layout | [Narrow](narrow.png) |

[results.json](results.json) contains the instrumented binary hash, native state,
window geometry, checks and the large-directory observation. `session/` contains
fixture-app and compositor logs. The large-directory test creates 10,000 files;
the grid realizes 513 children, rather than one widget per file.

The screenshot geometry is taken directly from the compositor. Theme and font
rendering follows the installed GTK/icon/font environment; these are not browser
renders or manually altered images. See the [implementation report](../../docs/IMPLEMENTATION.md)
for scope and limitations.

The private compositor emits inactive-text-input diagnostics during the virtual
keyboard runs. The application checks use fatal GTK warnings and must exit cleanly;
physical input-method and assistive-technology qualification remains open.
