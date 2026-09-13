# Pearl component system (T03)

The GTK gallery now demonstrates the first reusable Material-style component
set, using the existing Zig 0.16.0/Ghostty stack. Start it in a private nested
Aqueous session:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build gallery -Doptimize=ReleaseSafe -Ddev-backend=nested
```

The gallery opens maximized, with scrollable content. Buttons at the top switch
light/dark palettes, compact density, larger text, reduced motion and English/
German. They change only this running gallery, not desktop preferences. The
control-center tiles, workspace pills and launcher activation demonstrate local
widget behavior; they do not claim to control real services or windows.

## Component and theme ownership

`src/theme/theme.zig` contains semantic dark/light palettes and design constants.
`resources/style.css` is the shared template expanded for each palette; every
selector is rooted in `.pearl-root.pearl-dark` or `.pearl-root.pearl-light`.
Application-scoped classes select compact, large-text and reduced-motion variants.
The CSS provider is owned by the existing application lifecycle and removed at
shutdown. Widgets contain no local palette values. Color contrast tests cover
body, secondary, selected and error text against their intended backgrounds.

`src/ui/components/widgets.zig` provides cards, icon buttons, pills, tiles,
section rows, switches/sliders through GTK's native controls, responsive flow
containers and empty/error/pending presentations. Constructors return floating
widgets; the receiving GTK parent takes ownership. Titles and descriptions wrap
by word, with a character fallback for long unbroken text. Focus rings, hover,
pressed, checked and disabled states share the same CSS. Background tinting does
not lower foreground or subtree opacity. Pending indicators are static.

Eleven original symbolic SVG icons are compiled into GResource. GTK recolors the
same artwork for each palette and selected state. System Inter is requested,
with a sans-serif fallback; no DMS fonts or artwork are vendored.

`src/ui/gallery.zig` composes the components. The fixture workspace pills are
read through T02's real decoder/reducer. The launcher contains six named sample
entries and 512 numbered entries for exercising a large list. It uses
`GtkStringList → GtkStringFilter → GtkFilterListModel → GtkSingleSelection →
GtkListView`, with a recycling `GtkSignalListItemFactory` and a bounded-height
scroller. Unicode case-insensitive filtering is handled by GTK. Filter edits
clear stale selection through the selection model; Enter activates the selected
sample by displaying feedback, never launching a process.

Gallery signal connections hold explicit object references and disconnect before
releasing them. Parent widgets own the model/factory chain. All GTK work stays
on the main thread. The T01 worker/cancellation path remains in the calendar
preview and drains before teardown. Gallery state must live at a stable address
while callbacks reference it. The application tracks representative models and
factory objects with weak references in its instrumented lifecycle tests.

## Translation, accessibility and motion

`src/ui/i18n.zig` supplies compiled English and German catalogs with checked key
coverage and UTF-8. The initial language follows the environment and unsupported
languages fall back to English. The gallery language button retranslates labels,
accessible names, tooltips and pending/ready/error preview text. Sample application
and window names are content identities and are not translated. Additional
languages can supply the same catalog keys; gettext tooling is not required by
this first component slice.

Native GTK buttons, toggles, switches, scales, search entry and list items provide
their normal accessible roles and keyboard behavior. Icon-only buttons have an
explicit accessible label and tooltip. Sliders/switches and the result list have
accessible names. Default list activation and arrow navigation stay in GTK.

| Keys | Action |
| --- | --- |
| Tab / Shift+Tab | Move through controls |
| Space | Activate focused buttons/toggles/switches |
| Arrow keys | Adjust scales or navigate the result list |
| Ctrl+F | Focus search |
| Down from search | Focus the selected result |
| Enter | Activate the selected sample result |
| Escape | Clear search and return focus to it |
| Ctrl+L / Ctrl+D | Toggle light palette / compact density |
| Ctrl+E / Ctrl+R | Toggle larger text / reduced motion |
| Ctrl+G | Switch English/German |
| Ctrl+Home / Ctrl+End | Focus the first / last gallery control and reveal it |

Reduced motion disables CSS transitions and GTK animations in this process. A
system setting that already disables animations remains respected. The original
GTK setting is restored when the gallery is destroyed. There are no production
frame callbacks, spinners or recurring gallery timers. GTK's native focused text
cursor and transient search/interaction behavior remain native GTK behavior.

## Review and validation

[Side-by-side visual review](../artifacts/t03/comparison.html) presents unmodified
Pearl captures beside the frozen T00 DMS control-center, launcher and settings
references. It switches palette and density without altering the screenshots.
[Recorded component checks](../artifacts/t03/latest/results.json) accompany the
captures; [lifecycle checks](../artifacts/t03/lifecycle/results.json) cover
repeated startup/shutdown, cancellation and resource/GObject cleanup.

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-components -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build integration -Doptimize=ReleaseSafe -- --output "$PWD/artifacts/t03/lifecycle"
```

`test-components` requires the T00 diagnostic Aqueous binary, `aqueousctl`,
`wtype`, `wlr-randr`, `grim` and a writable private Unix-socket environment.
It sends keys only to its own display and changes only its private headless
output for the narrow-layout case. It uses fatal GTK warnings, checks Pango label
widths against allocated widths, samples the realized row count, and exercises
search, activation, Tab traversal, switches and sliders. Test-only F12 reports
widget metrics; F10 schedules two one-shot idle samples. Those shortcuts are
compiled out of the ordinary application. Idle sampling avoids injecting input
during the measured interval and allows at most one final toolkit settling frame.

The gallery embeds the sanitized GPL-3.0-only Aqueous desktop fixture only for
demo use; its complete license text is also in the compiled resources. Provenance
remains in `tests/fixtures/aqueous/`. Session mode loads its separate session UI
and does not instantiate gallery fixture models.

## Deliberate visual differences and remaining checks

| Difference from the frozen DMS reference | Reason / next owner |
| --- | --- |
| Native GTK title bar and a gallery header | Review controls, not final shell placement; T05/T06 own surfaces |
| Opaque tonal cards | T05 integrates Aqueous's advertised native background-blur protocol |
| Noto Sans on this machine | Inter is not installed; no DMS font assets are copied |
| Original line icons | Matches the symbolic hierarchy without depending on Material Symbols |
| Larger composition around the sample panels | Gallery exposes states and controls together; compact density reduces component padding |
| Static profile, calendar and service values | Deterministic fixture content; live adapters belong to later tasks |

The captured DMS baseline has default density; Pearl's compact variant is compared
against that same frozen baseline rather than claiming a separate DMS compact
capture. Pixel-identical typography and final panel geometry are not claimed.
Screen-reader verification with a real accessibility bus and physical mixed-DPI
monitor checks remain release validation; this private suite exercises widget
semantics, keyboard interaction and measured text layout.
