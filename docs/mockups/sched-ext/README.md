# System scheduler mockup

Open [index.html](index.html) directly in a browser. This offline HTML/CSS/JS
prototype shows the proposed System tab from the
[sched-ext implementation plan](../../SCHED_EXT_IMPLEMENTATION_PLAN.md).
All state is illustrative and kept in memory. No system commands are executed.

Choose a scheduler and mode, inspect its resolved arguments, and select
**Apply scheduler**. The current scheduler changes after a simulated delay.
**Use kernel default** returns to the initial state. Selecting scx_beerland
demonstrates a mode without configured arguments.

The preview toolbar offers running, missing scxctl, missing binaries,
unavailable loader, and failed application scenarios. **Light preview** changes
appearance. At narrow widths, **Sections** opens navigation. Other sidebar
destinations link to the existing Settings navigation prototype.

| Capture | Preview |
| --- | --- |
| Dark desktop | [desktop.png](desktop.png) |
| Light desktop | [light.png](light.png) |
| Narrow layout | [narrow.png](narrow.png) |
| Missing dependency | [unavailable.png](unavailable.png) |

Direct links accept `?theme=light` and `?state=active`, `missing`, `binaries`,
`offline`, or `failure`.

Chromium/Playwright checks passed for staged selection, apply, stop, empty mode
arguments, dependency states, simulated failure, already-applied selection,
theme switching, compact navigation, and horizontal overflow at 390 and 480
pixels. No JavaScript errors were observed. Desktop and narrow captures were
visually inspected. This validates the prototype; native GTK integration and
scxctl operation remain proposed work.
