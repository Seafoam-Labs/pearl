# Window rule builder mockup

Open [index.html](index.html) in a browser. It works offline and uses no external
assets, network requests, browser storage or compositor connection.

[Implementation plan](../../WINDOW_RULES_BUILDER_IMPLEMENTATION_PLAN.md)

The proposal reuses the notification rule builder's editor structure and adds
typed window settings. It preserves Aqueous's all-conditions / first-match-wins
semantics and generation-scoped shared draft. Names, enable switches, Any
matching and case-folding are deliberately absent because the current window
rule schema does not support them.

## Views

| Layout | Capture |
| --- | --- |
| Ordered window-rule cards | [Desktop](desktop.png) |
| Conditions and window settings | [Editor](editor.png) |
| First winning rule and later matches | [Tester](test.png) |
| Light theme | [Light](light.png) |
| Compact navigation at 560px | [Narrow](narrow.png) |
| 390px page | [Compact](compact.png) |
| 390px editor | [Compact editor](editor-390.png) |
| Older helper without testing support | [Unavailable tester](unsupported.png) |

Direct states: `?view=editor`, `?view=test`, `?theme=light`, `?empty=1`, and
`?support=limited&view=test`. Desktop captures use 1440×1080; compact captures
use 560×1020 and 390×1020. Dialogs scroll independently and keep their actions
outside the scrolling form.

Try Add rule, Add condition, Add setting, Edit, Cancel, Delete, Validate,
Apply and Discard. Arrow buttons stage one isolated move; further rule edits
wait for Apply/Discard, matching the current mutation constraint. Test window
reports the first winner and marks subsequent matches as not applied. Editing
a sample or draft clears its old result.

## Verification and limits

`python3 docs/mockups/window-rules/verify.py` runs the local Playwright/Chromium
checks and refreshes screenshots. [verification.json](verification.json) records
23 passing checks including explicit Off/zero values, reversible deletion,
unique matcher fields, ordering guards, sample matching, capability fallback,
Escape/focus restoration, short dialogs, and no horizontal overflow at 390/560px.
No JavaScript runtime errors were observed.

This is an HTML layout prototype, not the native implementation. The browser
matcher illustrates bounded byte globs for the sample fields; the production
tester must use Aqueous's authoritative parser/resolver and a newly advertised
read-only capability. Validate/Apply only update in-memory sample state and do
not implement helper validation, receipts, protected confirmation, reload,
external edits, concurrency, source preservation, or filesystem persistence.

The prototype includes five matcher fields and ten common effects. It assumes
managed windows, treats a blank test tag as absent, and omits the advanced empty
pattern, explicit empty tag, X11 scope/type and full effect-schema controls.
The implementation plan covers those semantics and preservation requirements.
Existing no-effect barrier rules, unknown fields and numeric/identity budgets
also require native tests. Navigation entries are contextual labels rather
than functioning destination pages. Browser checks are not native GTK or
screen-reader acceptance.
