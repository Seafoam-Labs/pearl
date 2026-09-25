# Workspace window switcher concept

Open [index.html](index.html) directly in a browser. No server, dependencies,
network connection or running Pearl session is required.

The [implementation plan](../../WINDOW_SWITCHER_IMPLEMENTATION_PLAN.md) defines
the native behavior, Aqueous dependency, delivery sequence and acceptance checks.

- Click **Cycle →** or the bar's stack button to bring the next window forward.
- Use **←** or the left/right arrow keys to cycle in either direction.
- Three forward presses return to the initial window, preserving stable order.
- Try the **1 window** and **Empty workspace** samples.
- Enable **Reduced motion** for instantaneous changes. The operating system's
  reduced-motion media preference also disables transitions.
- Uncheck **Keep switcher visible** to dismiss after 1.5 seconds without cycling.
  Escape dismisses immediately and keeps the current selection. Use the bar's
  cycle button to advance and reopen; **Reset demo** restores the initial sample.

The permanent review controls sit outside the simulated desktop. The titlebar
controls and sample application contents are decorative. This prototype does not
access real windows, change preferences or implement compositor input routing.
It compresses windows into a presentation stack; native dismissal will restore
the selected window's actual geometry, which the browser cannot demonstrate.

Captures: [desktop](desktop.png), [next window](next-window.png),
[narrow layout](narrow.png). Local browser checks and their limits are recorded
in [verification.json](verification.json).
