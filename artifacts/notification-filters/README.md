# Notification filters — implementation evidence

The native **Settings → Notifications** page now includes configurable filters
between Do Not Disturb and recent history. DND remains immediate; filter edits
use the shared preference draft and Apply/Discard. The page has a rule editor,
master/per-rule switches, and a read-only sample tester using the same Unicode
matcher as notification delivery.

- [Acceptance report](verification.json)
- [Dark theme](session/native-static-dark.png)
- [Light theme](session/native-static-light.png)
- [GTK theme](session/native-gtk-light.png)
- [Rule editor](session/native-rule-editor.png)
- [Sample tester](session/native-tester.png)
- [390px layout](session/native-390.png)
- [390px rule editor](session/native-editor-390.png)
- [Large text in a short window](session/native-large-text-short.png)
- [Another notification owner](session/native-foreign-owner.png)

Run `ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-notification-filter-settings -Doptimize=ReleaseSafe`.
The private-session test uses actual GTK input, D-Bus clients, isolated XDG
configuration, and `G_DEBUG=fatal-warnings`. The report records binary hashes.
The original [browser mockup](../../docs/mockups/notification-filters/index.html)
remains a design reference; these captures show the implemented native UI.

Physical monitor and screen-reader acceptance remains a manual check. These
captures and automation do not claim an Orca review.

## Regression results

[Regression reports](regressions.json) record a passing ReleaseSafe production
build, model/Unicode unit tests,
`test-session-services`, `test-preferences`, `test-settings-boundary`, and
`test-settings-devices` (including live notification actions and 480px resizing).
The Notifications footer stacks its explanation and buttons so its initial
minimum width permits compact placement before the resize callback runs.

`test-settings-services` remains failing in the Aqueous editor's Apply check:
the outcome stays `validated`. This suite also fails on unchanged HEAD, at a
later display-preview shutdown check. That comparison establishes broader
suite instability, but does **not** prove the exact Apply timeout pre-existing.
The notification-specific suite independently verifies native Apply/Discard,
shared drafts, ownership, and runtime publication.
