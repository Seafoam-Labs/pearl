# Native Plugins layout

The native Zig Settings page implements the
[interactive proposal](../../docs/mockups/plugins/index.html): compact status
cards, explicit package review, optional permissions, expandable settings and
diagnostics, page-scoped search/filters, discovery feedback, and the existing
shared Apply & save / Discard footer.

The desktop illustration uses native GTK widgets and Pearl theme colors. Plugin
Preview sends the existing synthetic event to the saved runtime; it does not
render the HTML mockup's simulated dialog. No preference schema migration is
required. The live page adds an optional `discovery_issue` field so discovery
failures and rejected packages remain visible outside the disclosure.

Native validation lives in
[test_plugins_layout.py](../../tests/integration/test_plugins_layout.py), with
results in [verification.json](native/verification.json). All sessions use
private XDG roots and installed sample packages. Captures include
[dark](native/session/dark.png), [light](native/session/light.png),
[560 px](native/session/narrow.png), [390 px](native/session/compact.png),
[review](native/session/review.png), and
[compact review](native/session/compact-review.png).

Validation passed: [298 unit tests](unit-results.txt),
[14 native layout/review checks](native/verification.json), and
[9 existing plugin runtime regression checks](runtime-results.json). Production
and instrumented Settings builds passed in ReleaseSafe mode. Dark, light and
compact native captures were visually reviewed; no GTK warnings were observed.

Run `zig build test-plugins-layout -Doptimize=ReleaseSafe` with the repository's
private Aqueous fixture and built plugin examples available. To exercise the
runtime too, add `-Dwasm-plugins=true` and the verified `-Dwasmtime-prefix` used by
the other plugin suites. Runtime regressions remain covered by
`tests/integration/test_plugins.py`; document and protocol tests run with
`zig build test-plugin-unit`.
