# M2 native workbench visual alignment

Implemented before starting M3, following the user's request to bring the existing native workbench closer to the [interactive design](mockups/workbench/index.html). This is alignment of the **implemented M2 surfaces**, not pixel-identical reproduction or delivery of the mockup's simulated services. M3 has not started.

## Delivered layout

- Compact Coral titlebar with brand, workspace/recent-projects menu, centered command-palette button, file actions and categorized application menu. Every existing action remains available. Secondary header controls collapse on small windows.
- 48px activity rail with active-panel indication; default 222px Explorer; flat 40px tabs/panel headers, 29px explorer rows and 26px status bar. These are nominal logical-pixel geometry targets, not fixed device-pixel guarantees across GTK themes/fonts.
- Real **33px per-group breadcrumbs** below the tabs, including workspace/root identity, relative document paths and excerpt identification. Long paths ellipsize with full tooltips. Each group follows its own selected page. Editor pages remain their existing scrolled windows; view/session identities and scroller children are unchanged.
- Readable root-qualified tabs with an accent top edge. Label requests adapt to the group's width; long labels retain a tooltip.
- Compact Explorer toolbar: Roots, Back, Rescan, New file. **Explorer actions and safety information** exposes folder/workspace opening, remaining reviewed file operations, Reset tree, Close workspace and safety details. Review/confirmation requirements are unchanged.
- Dock **Panel options** exposes left/right/bottom placement, grow/shrink and reset; Hide remains directly accessible. Splitters keep their native pointer hit targets.
- Real workspace/trust information and caret/encoding/newline state in the status bar. Narrow windows retain caret and trust; full document state stays available in a tooltip. No fabricated branch, language-server or agent status.
- At content widths below 520px, the active auxiliary panel is presented beneath the editor. Desired side placement remains saved and returns when widened. This deliberately uses a native bottom panel rather than the mockup's overlay drawer.
- Coral Dark/Light palettes and shipped source schemes now use the design's charcoal/coral and warm-light colors. Palette validation still checks semantic text contrast. Native GTK keeps native colors; committed Follow Pearl palettes/fonts/motion still use their existing supplied roles and per-window ownership. Geometry uses `coral-workbench`, separate from custom-color `coral` scoping.
- Dark command/picker/dialog lists, titlebars and preference spin fields have matching readable surfaces.

Existing saved dock sizes are honored. The 222px sidebar applies to new/default/reset layouts and older session formats that use defaults; there is no session-format migration.

## Intentional differences and limits

The mockup's Git rail/status, Problems/LSP UI, terminal and agent panel remain absent until their real service milestones. No blank or simulated panels were added to fill their space. GTK window controls, native icons, actual notifications and safety notices remain visible. Command search uses the existing `Ctrl+Shift+P` palette; Quick Open remains `Ctrl+P`. The centered command control uses its natural text width rather than a fixed 470px mockup width.

Editor font preferences and Native GTK/Follow Pearl semantics take precedence over literal screenshot typography. Breadcrumbs describe real paths, not LSP symbols. This is not full accessibility/IME or physical GPU/input-to-paint qualification. A pre-existing programmatic shrink from 1440px to 390px can initially settle wider and require another resize; direct 390px startup and widening/restoration were validated.

## Validation

Run from `pearl/subprojects/coral`:

```sh
zig build visual -Doptimize=safe -j1
zig build test-m2 -Doptimize=safe -j1 --summary all
zig build test -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all
```

The new standalone `visual` target uses private HOME/XDG, accessibility bus, D-Bus and headless Wayland fixtures, real files and actual pointer/keyboard interaction. It is separate from `test-m2`, requires the existing Aqueous fixture plus grim/wtype/PyGObject/AT-SPI/Pillow, and never drives the live desktop. Reports retain screenshot/binary/scheme hashes, allocations, accessibility trees, actions and failures. Screenshots are native GTK captures, not mockup exports.

### Final results for this change

| Check | Result |
| --- | --- |
| Native visual matrix | **16/16 passed**: dark/light at 1440, 1024, 700, 390px; Native GTK and offline Follow Pearl at 1024/390 with normal/doubled fonts |
| Font checks | Four comparisons passed at **2.0×** editor font scaling |
| Widget suite | **201/201 passed**, including new breadcrumb, selection-mark and tab-width regressions |
| All native M1/M2 suites | **271/271 passed** across 13 harnesses in the latest aggregate |
| Latest aggregate command | **Failed**, despite passing widget/native suites: an unchanged process-supervisor unit test aborted; see caveat below |
| Standalone unit recheck | **50/50 build steps; 326/326 main-root tests freshly passed**; four other unit runners cached |
| Production build | **46/46 steps passed**, with fresh hooks-disabled executable compilation |
| Formatting / whitespace | Zig formatting and `git diff --check` passed |

**Do not describe the latest aggregate as green.** `capture supervisor shutdown cancels owned jobs only, including spawn race` aborted at `src/tasks/process_test.zig:505` during deferred destruction. No process implementation or test was changed. The standalone unit rerun passed without edits; the intermittent failure's cause remains unproven and merits separate investigation. Latest aggregate elapsed 21m23.563s; production build 27.130s. Historical M2 closure evidence remains separate.

Earlier attempts caught two actual issues in this pass, both fixed without weakening assertions:

1. Moving Explorer beside split groups could leave focus on an ancestor paned while GTK remapped the row. Bounded repair now recognizes only ancestor wrapper/paned fallback and does not override explicit focus elsewhere.
2. GtkSourceView search rendering moved private marks during paint, triggering shell updates and a status-box snapshot allocation warning. Full/excerpt mark handlers now react only to insertion/selection-bound marks. **32 focused startup repetitions**, then the final native project suite, passed.

Native counts: 40 workflows, 14 groups, 13 recovery, 18 workspaces, 19 explorer, nine search, 17 policy, 19 sessions, 27 docks, 27 windows, 25 operations, 25 projects and 18 roots. Counts are suite check groups, not additive unique unit-test totals.

The visual matrix produced **102 window captures and 64 full-output captures**. Wide dark, medium light, narrow dark, command-palette and preference screenshots were inspected. **Follow Pearl visual coverage is offline fallback only**, not live committed appearance delivery; existing scoped-palette tests remain in the unit/widget suites. Rendering uses headless Cairo, with no pixel-identical golden assertion across GTK/font versions.

## Local evidence and screenshots

These are local ignored artifacts, not bundled release assets:

- [Visual results](../../../.cache/coral-visual/results.json), [visual log](../../../.cache/coral-visual-accepted.log)
- [Latest aggregate log, including unit crash](../../../.cache/coral-m2-visual-accepted.log)
- [Passing unit recheck](../../../.cache/coral-m2-visual-unit-recheck.log)
- [Production build](../../../.cache/coral-m2-visual-accepted-production.log)
- Earlier retained aggregate failures: `pearl/.cache/coral-m2-visual-full.log` and `pearl/.cache/coral-m2-visual-final.log`
- [1440px dark native workbench](../../../.cache/coral-visual/screenshots/dark-1440-workbench.png)
- [700px light native workbench](../../../.cache/coral-visual/screenshots/light-700-workbench.png)
- [390px dark native workbench](../../../.cache/coral-visual/screenshots/dark-390-workbench.png)
- [Dark command palette](../../../.cache/coral-visual/screenshots/dark-390-command-center-output.png)
- [Dark preferences](../../../.cache/coral-visual/screenshots/dark-390-preferences-output.png)

Next implementation milestone remains **M3 language intelligence**. M9 remains removed.
