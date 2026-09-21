# Native Coral verification

These are captures of the running Zig/GTK4 application in a private Aqueous
Wayland session, using temporary text files and an isolated Hunspell dictionary.
The [results report](results.json) records checks, binary hash, window dimensions,
state metadata and the 1 MiB measurement. Images are not browser mockups.

| State | Capture |
| --- | --- |
| Pearl dark editor | [Editor](editor-dark.png) |
| Pearl light editor | [Light](editor-light.png) |
| Real Enchant suggestions | [Spelling](spelling.png) |
| Find and replace | [Search](search.png) |
| Unsaved document | [Save prompt](unsaved.png) |
| External file change | [Conflict](file-conflict.png) |
| Preferences | [Preferences](preferences.png) |
| Dictionary unavailable | [Missing dictionary](missing-dictionary.png) |
| Native GTK theme | [Native theme](native-theme.png) |
| Narrow window | [480 px](narrow.png) |
| System text at 200% | [Scaled text](text-200-percent.png) |
| Large-file decision | [Large file](large-file.png) |

Regenerate from `subprojects/coral`:

```sh
zig build integration -Doptimize=ReleaseSafe
```

The harness uses the existing Pearl private-session tooling. It does not modify
host settings, MIME defaults, dictionaries, or user files. Read the
[implementation report](../../docs/IMPLEMENTATION_STATUS.md) for limitations and
manual qualification still required.
